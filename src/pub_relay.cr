require "http"
require "json"
require "openssl_ext"
require "redis"
require "sidekiq"
require "i18n"

require "./actor"
require "./relay_activity"
require "./inbox_handler"
require "./controller_inbox_handler"

class PubRelay
  VERSION = "0.2.0"

  include HTTP::Handler

  # Make sidekiq use REDIS_URL
  ENV["REDIS_URL"] ||= "redis://localhost:6379"
  ENV["REDIS_PROVIDER"] = "REDIS_URL"
  Sidekiq::Client.default_context = Sidekiq::Client::Context.new

  class_getter redis = Redis::PooledClient.new(url: ENV["REDIS_URL"])

  class_property(private_key) do
    private_key_path = ENV["RELAY_PKEY_PATH"]? || File.join(Dir.current, "actor.pem")
    OpenSSL::PKey::RSA.new(File.read(private_key_path))
  end

  class_property(host) { ENV["RELAY_DOMAIN"] }

  class_property logger = Logger.new(STDOUT)

  def call(context : HTTP::Server::Context)

    case {context.request.method, context.request.path}
    when {"GET", "/.well-known/webfinger"}
      serve_webfinger(context)
    when {"GET", "/.well-known/nodeinfo"}
      serve_nodeinfo_wellknown(context)
    when {"GET", "/nodeinfo/2.0"}
      serve_nodeinfo_2_0(context)
    when {"GET", "/actor"}
      serve_actor(context)
    when {"GET", "/controller"}
      serve_controller(context)
    when {"POST", "/inbox"}
      handle_inbox(context)
    when {"POST", "/controller/inbox"}
      handle_controller_inbox(context)
    when {"GET", "/actor/followers"}
      serve_actor_followers(context)
    when {"GET", "/controller/followers"}
      serve_controller_followers(context)
    when {"GET", "/list"}
      instance_list(context)
    else
      unless handle_activity(context)
        call_next(context)
      end
    end
  end

  private def serve_webfinger(ctx)
    resource = ctx.request.query_params["resource"]?
    return error(ctx, 400, "Resource query parameter not present") unless resource

    case resource
    when account_uri
      ctx.response.content_type = "application/json"
      {
        subject: account_uri,
        links:   {
          {
            rel:  "self",
            type: "application/activity+json",
            href: route_url("/actor"),
          },
        },
      }.to_json(ctx.response)
    when controller_uri
      ctx.response.content_type = "application/json"
      {
        subject: controller_uri,
        links:   {
          {
            rel:  "self",
            type: "application/activity+json",
            href: route_url("/controller"),
          },
        },
      }.to_json(ctx.response)
    else
      return error(ctx, 404, "Resource not found")
    end
  end

  private def serve_nodeinfo_wellknown(ctx)
    ctx.response.content_type = "application/json"
    {
      links:   {
        {
          rel:  "http://nodeinfo.diaspora.software/ns/schema/2.0",
          href: route_url("/nodeinfo/2.0"),
        },
      },
    }.to_json(ctx.response)
  end

  private def serve_nodeinfo_2_0(ctx)
    ctx.response.content_type = "application/json; profile=http://nodeinfo.diaspora.software/ns/schema/2.0"
    {
      openRegistrations: true,
      protocols:         ["activitypub"],
      services:          {
        inbound:  [] of String,
        outbound: [] of String,
      },
      software: {
        name:    "selective-relay",
        version: "#{PubRelay::VERSION}",
      },
      usage: {
        localPosts: 0,
        users:      {
          total: 2,
        },
      },
      version: "2.0",
      metadata: {
        peers: PubRelay.redis.keys("subscription:*").map(&.as(String).lchop("subscription:"))
      }
    }.to_json(ctx.response)
  end

  private def serve_actor(ctx)
    ctx.response.content_type = "application/activity+json"
    RelayActor.make_actor_activity.to_json(ctx.response)
  end

  private def serve_controller(ctx)
    ctx.response.content_type = "application/activity+json"
    RelayActor.make_controller_activity.to_json(ctx.response)
  end

  private def serve_actor_followers(ctx)
    if ctx.request.query_params.has_key?("page")
      ctx.response.content_type = "application/json"
      {
        "@context"     => "https://www.w3.org/ns/activitystreams",
        "id"           => route_url("/actor/followers"),
        "type"         => "OrderedCollectionPage",
        "totalItems"   => 0,
        "partOf"       => route_url("/actor/followers"),
        "orderedItems" => [] of String,
      }.to_json(ctx.response)
    else
      ctx.response.content_type = "application/json"
      {
        "@context"     => "https://www.w3.org/ns/activitystreams",
        "id"           => route_url("/actor/followers"),
        "type"         => "OrderedCollection",
        "totalItems"   => 0,
        "first"        => route_url("/actor/followers?page=1"),
      }.to_json(ctx.response)
    end
  end

  private def serve_controller_followers(ctx)
    if ctx.request.query_params.has_key?("page")
      ctx.response.content_type = "application/json"
      {
        "@context"     => "https://www.w3.org/ns/activitystreams",
        "id"           => route_url("/controller/followers"),
        "type"         => "OrderedCollectionPage",
        "totalItems"   => 0,
        "partOf"       => route_url("/controller/followers"),
        "orderedItems" => [] of String,
      }.to_json(ctx.response)
    else
      ctx.response.content_type = "application/json"
      {
        "@context"     => "https://www.w3.org/ns/activitystreams",
        "id"           => route_url("/controller/followers"),
        "type"         => "OrderedCollection",
        "totalItems"   => 0,
        "first"        => route_url("/controller/followers?page=1"),
      }.to_json(ctx.response)
    end
  end

  private def handle_inbox(context)
    InboxHandler.new(context).handle
  end

  private def handle_controller_inbox(context)
    ControllerInboxHandler.new(context).handle
  end

  private def handle_activity(context)
    request_path = route_url(context.request.path)
    request_path = PubRelay.redis.hget("redirect", request_path) || request_path
    if context.request.method == "GET" && PubRelay.redis.hexists("activity", request_path)
      context.response.content_type = "application/activity+json"
      PubRelay.redis.hget("activity", request_path).to_s(context.response)
      true
    else
      false
    end
  end

  private def instance_list(ctx)
    instances = [] of String
    @@redis.keys("subscription:*").each do |key|
      key = key.as(String)
      domain = key.lchop("subscription:")
      instances.push("https://#{domain}")
    end

    ctx.response.content_type = "application/json"
    {
      last_updated: Time.utc.to_unix,
      instances:    instances,
    }.to_json(ctx.response)
  end

  def account_uri
    "acct:relay@#{PubRelay.host}"
  end

  def controller_uri
    "acct:relayctl@#{PubRelay.host}"
  end

  def self.route_url(path)
    "https://#{host}#{path}"
  end

  def route_url(path)
    PubRelay.route_url(path)
  end

  private def error(context, status_code, message)
    context.response.status_code = status_code
    context.response.puts message
  end
end
