require "./signature_verification"
require "./activity"
require "./deliver_worker"
require "./instance"
require "./nodeinfo"
require "./misskey_user"
require "string_scanner"
require "uuid"
require "uuid/json"

class ControllerInboxHandler
  include SignatureVerification
  include I18nHelper

  def handle
    request_body, actor_from_signature = verify_signature

    begin
      activity = Activity.from_json(request_body)
    rescue ex : JSON::Error
      error(400, "Invalid activity JSON\n#{ex.inspect_with_backtrace}")
    end

    case activity
    when .note?
      handle_note(actor_from_signature, activity)
    when .follow?
      error(400, "Following is not allowed.")
    end

    response.status_code = 202
    response.puts "OK"
  rescue ignored : SignatureVerification::Error
    # error output was already set
  end

  def record_actor_inbox(actor)
    redis.hsetnx("connection:#{actor.domain}", "inbox_url", actor.inbox_url)
  end

  def parse_argument(argument_string : String) : {String, Array(String), Hash(String, Array(String))}
    tokens = argument_string.split(/\s+/).reject(&.blank?)
    cmd = ""
    args = [] of String
    opts = {} of String => Array(String)

    if tokens.size >= 2 && tokens.shift.starts_with?("@relayctl")
      cmd = tokens.shift
      tokens.each do |token|
        case token
        when .starts_with?('@')
          next
        when .starts_with?(':')
          opt_tokens = token.lchop.split(':')
          opts[opt_tokens.shift] = opt_tokens
        else
          args << token
        end
      end
    end
    {cmd, args, opts}
  end

  macro reply(message)
    create_note(actor, {{message}}, activity.object_id_string)
  end

  macro reply_json(message)
    create_note(actor, {{message}}, activity.object_id_string, json: true)
  end

  def handle_note(actor, activity)
    record_actor_inbox(actor)
    cmd, args, opts = parse_argument(activity.content_text)
    options = get_general_options(actor, opts)
    lang = options["lang"]
    I18n.locale = I18n.available_locales.includes?(lang) ? lang : activity.lang

    case cmd
    when "hello"
      reply t("hello", {name: actor.displayname})
    when "status"
      send = [] of String
      receive = [] of String
      # admin = false
      send_disabled = false
      send_deny_domains = [] of String
      subscribe_tags = [] of String
      subscribe_accts = [] of String
      set_options = [] of String

      set_options << ":server" if get_user_servermode(actor)
      set_options << ":json" if get_user_jsonmode(actor)
      set_options << ":quiet" if get_user_quietmode(actor)
      set_options << ":verbose" if get_user_verbosemode(actor)

      set_default = set_options.join(" ")

      if get_user_send_disabled(actor)
        send << t("disabled")
      else
        send << t("server") if server_subscription?(actor)
        send << t("user") if follow?(actor)
      end
      receive << t("server") if server_subscription?(actor)
      receive << t("user") if user_subscription?(actor)
      lang = get_user_lang(actor)
      send_deny_domains += get_user_send_deny_domains(actor)
      subscribe_tags += get_subscribe_tags(actor)
      subscribe_accts += get_subscribe_accts(actor)

      status = {
        send:              send,
        receive:           receive,
        lang:              lang,
        set_default:       set_default,
        send_deny_domains: send_deny_domains,
        # admin:     admin,
        subscribe_tags:  subscribe_tags,
        subscribe_accts: subscribe_accts,
      }
      if opts.has_key?("json") || get_user_jsonmode(actor)
        reply_json status.to_json
      else
        reply "<br>#{status.to_mes}"
      end
    when "subscribe"
      messages = [] of String

      tag_count, tags = subscribe_tags(actor, args.select(&.starts_with?('#')))
      messages << t("subscribe_tags_mes", count: tag_count) << tags.join(" ") if tag_count > 0

      acct_count, accts = subscribe_accts(actor, args.reject(&.starts_with?('#')))
      messages << t("subscribe_accts_mes", count: acct_count) << accts.join(" ") if acct_count > 0

      messages << t("subscribe_nothing") if tag_count == 0 && acct_count == 0

      reply messages.join("<br>") unless opts.has_key?("quiet") || get_user_quietmode(actor)
    when "unsubscribe"
      messages = [] of String

      if opts.has_key?("all")
        tag_count = unsubscribe_all_tags(actor)
        messages << t("unsubscribe_tags", count: tag_count) if tag_count > 0
        acct_count = unsubscribe_all_accts(actor)
        messages << t("unsubscribe_accts", count: acct_count) if acct_count > 0
      else
        if opts.has_key?("all-tag")
          tag_count = unsubscribe_all_tags(actor)
          messages << t("unsubscribe_tags", count: tag_count) if tag_count > 0
        else
          tag_count, tags = unsubscribe_tags(actor, args.select(&.starts_with?('#')))
          messages << t("unsubscribe_tags", count: tag_count) << tags.join(" ") if tag_count > 0
        end
        if opts.has_key?("all-account")
          acct_count = unsubscribe_all_accts(actor)
          messages << t("unsubscribe_accts", count: acct_count) if acct_count > 0
        else
          acct_count, accts = unsubscribe_accts(actor, args.reject(&.starts_with?('#')))
          messages << t("unsubscribe_accts", count: acct_count) << accts.join(" ") if acct_count > 0
        end
      end

      messages << t("unsubscribe_nothing") if tag_count == 0 && acct_count == 0

      reply messages.join("<br>") unless opts.has_key?("quiet") || get_user_quietmode(actor)
    when "join"
      if opts.has_key?("server") || get_user_servermode(actor)
        domain = actor.domain
        unless is_admin?(domain, actor.acct)
          reply t("not_admin_acct", options: {domain: domain, acct: actor.acct}) unless opts.has_key?("quiet") || get_user_quietmode(actor)
          return
        end

        # for Server
        PubRelay.redis.hset("subscription:#{domain}", "inbox_url", actor.inbox_url)
        reply t("join_domain_success", options: {domain: domain}) unless opts.has_key?("quiet") || get_user_quietmode(actor)
      else
        # for User
        if follow?(actor)
          reply t("join_already") unless opts.has_key?("quiet") || get_user_quietmode(actor)
        else
          follow(actor)
          reply t("join_success") unless opts.has_key?("quiet") || get_user_quietmode(actor)
        end
      end
    when "leave"
      if opts.has_key?("server") || get_user_servermode(actor)
        domain = actor.domain
        unless is_admin?(domain, actor.acct)
          reply t("not_admin_acct", options: {domain: domain, acct: actor.acct}) unless opts.has_key?("quiet") || get_user_quietmode(actor)
          return
        end

        # for Server
        PubRelay.redis.del("subscription:#{domain}")
        reply t("leave_domain_success", options: {domain: domain}) unless opts.has_key?("quiet") || get_user_quietmode(actor)
      else
        # for User
        if follow?(actor)
          unfollow(actor)
          reply t("leave_success") unless opts.has_key?("quiet") || get_user_quietmode(actor)
        else
          reply t("leave_already") unless opts.has_key?("quiet") || get_user_quietmode(actor)
        end
      end
    when "send"
      if opts.has_key?("deny")
        case opts["deny"].first
        when "domains"
          add_count = set_user_send_deny_domains(actor, args)
          if args.size > 0
            reply t("send_deny_domains_mes", count: add_count) unless opts.has_key?("quiet") || get_user_quietmode(actor)
          else
            reply t("send_deny_domains_clear_mes") unless opts.has_key?("quiet") || get_user_quietmode(actor)
          end
        end
      end
      if opts.has_key?("enable")
        set_user_send_disabled(actor, false)
        reply t("set_send_enabled") unless opts.has_key?("quiet") || get_user_quietmode(actor)
      elsif opts.has_key?("disable")
        set_user_send_disabled(actor, true)
        reply t("set_send_disabled") unless opts.has_key?("quiet") || get_user_quietmode(actor)
      end
    when "receive"
      if opts.has_key?("server") || get_user_servermode(actor)
        domain = actor.domain
        unless is_admin?(domain, actor.acct)
          reply t("not_admin_acct", options: {domain: domain, acct: actor.acct}) unless opts.has_key?("quiet") || get_user_quietmode(actor)
          return
        end

      else
        # for User
        if opts.has_key?("deny")
          case opts["deny"].first
          when "actor-types"
            if args.size > 0
              # regist
            else
              # reset
            end
          end
        end
      end
    when "auth"
      if args.size == 1
        domain = args.first
      else
        domain = actor.domain
      end

      if is_admin?(domain, actor.acct)
        reply t("exist_admin_acct", options: {domain: domain, acct: actor.acct}) unless opts.has_key?("quiet") || get_user_quietmode(actor)
        return
      end

      admin_accts = [] of String

      begin
        admin_accts << fetch_mastodon_instance(domain).contact_acct(domain)
      rescue
      end

      begin
        nodeinfo = fetch_pleroma_nodeinfo(domain)
        nodeinfo.metadata.not_nil!.staff_accounts.not_nil!.each do |staff_account_id|
          admin_accts << actor_from_key_id(staff_account_id).acct
        rescue
        end
      rescue
      end

      begin
        admin_accts.concat fetch_misskey_admin_users(domain).map(&.acct(domain))
      rescue
      end

      admin_accts.uniq!

      unless opts.has_key?("quiet") || get_user_quietmode(actor)
        if admin_accts.empty?
          reply t("not_found_admin_acct", options: {domain: domain})
        elsif admin_accts.includes? actor.acct
          acct_count = add_admin(domain, actor.acct)

          if acct_count > 0
            reply t("add_admin_acct", options: {domain: domain, acct: actor.acct})
          else
            reply t("exist_admin_acct", options: {domain: domain, acct: actor.acct})
          end
        else
          reply t("reject_admin_acct", options: {domain: domain, acct: actor.acct})
        end
      end
    when "set"
      set_options = [] of String

      if opts.has_key?("lang")
        set_user_lang(actor, opts["lang"].first)
        set_options << ":lang:#{opts["lang"].first}"
      end
      if opts.has_key?("server")
        set_user_servermode(actor, opts["server"].first? != "off")
        set_options << ":server#{opts["server"].first? != "off" ? "" : ":off"}"
      end
      if opts.has_key?("json")
        set_user_jsonmode(actor, opts["json"].first? != "off")
        set_options << ":json#{opts["json"].first? != "off" ? "" : ":off"}"
      end
      if opts.has_key?("quiet")
        set_user_quietmode(actor, opts["quiet"].first? != "off")
        set_options << ":quiet#{opts["quiet"].first? != "off" ? "" : ":off"}"
      end
      if opts.has_key?("verbose")
        set_user_verbosemode(actor, opts["verbose"].first? != "off")
        set_options << ":verbose#{opts["verbose"].first? != "off" ? "" : ":off"}"
      end

      reply "#{t("set_default_change")} #{set_options.join(" ")}" unless opts.has_key?("quiet") || get_user_quietmode(actor)
    end
  end

  def get_general_options(actor : Actor, opts : Hash(String, Array(String))) : NamedTuple(lang: String?, server_mode: Bool)
    {
      lang:        opts.has_key?("lang") ? opts["lang"].first : get_user_lang(actor),
      server_mode: opts.has_key?("server") ? true : opts.has_key?("user") ? false : get_user_servermode(actor),
    }
  end

  def get_user_lang(actor : Actor) : String?
    redis.hget("user_options:others:#{actor.acct}", "lang")
  end

  def set_user_lang(actor : Actor, lang : String)
    redis.hset("user_options:others:#{actor.acct}", "lang", lang)
  end

  def get_user_servermode(actor : Actor) : Bool?
    redis.hget("user_options:others:#{actor.acct}", "servermode") == "true"
  end

  def set_user_servermode(actor : Actor, servermode : Bool)
    redis.hset("user_options:others:#{actor.acct}", "servermode", servermode.to_s)
  end

  def get_user_jsonmode(actor : Actor) : Bool?
    redis.hget("user_options:others:#{actor.acct}", "jsonmode") == "true"
  end

  def set_user_jsonmode(actor : Actor, jsonmode : Bool)
    redis.hset("user_options:others:#{actor.acct}", "jsonmode", jsonmode.to_s)
  end

  def get_user_quietmode(actor : Actor) : Bool?
    redis.hget("user_options:others:#{actor.acct}", "quietmode") == "true"
  end

  def set_user_quietmode(actor : Actor, quietmode : Bool)
    redis.hset("user_options:others:#{actor.acct}", "quietmode", quietmode.to_s)
  end

  def get_user_verbosemode(actor : Actor) : Bool?
    redis.hget("user_options:others:#{actor.acct}", "verbosemode") == "true"
  end

  def set_user_verbosemode(actor : Actor, verbosemode : Bool)
    redis.hset("user_options:others:#{actor.acct}", "verbosemode", verbosemode.to_s)
  end

  def get_user_send_deny_domains(actor : Actor) : Array(String)
    redis.smembers("user_options:send:deny:domains:#{actor.acct}").map(&.to_s)
  end

  def set_user_send_deny_domains(actor : Actor, args : Array(String))
    if args.size > 0
      redis.sadd("user_options:send:deny:domains:#{actor.acct}", args)
    else
      redis.del("user_options:send:deny:domains:#{actor.acct}")
    end
  end

  def get_user_send_disabled(actor : Actor) : Bool?
    redis.hget("user_options:others:#{actor.acct}", "disabled") == "true"
  end

  def set_user_send_disabled(actor : Actor, disable : Bool)
    redis.hset("user_options:others:#{actor.acct}", "disabled", disable.to_s)
  end

  def get_subscribe_tags(actor : Actor) : Array(String)
    tags = [] of String
    redis.smembers("user_options:subscribe_tag:#{actor.acct}").each do |tag|
      tags << tag.to_s
    end
    tags
  end

  def get_subscribe_accts(actor : Actor) : Array(String)
    accts = [] of String
    redis.smembers("user_options:subscribe_acct:#{actor.acct}").each do |acct|
      accts << acct.to_s
    end
    accts
  end

  def subscribe_tags(actor : Actor, tags : Array(String)) : {Int32, Array(String)}
    count = 0
    added_tags = [] of String
    tags.each do |tag|
      tag = tag.to_s.downcase
      if redis.sadd("subscribe:#{tag}:#{actor.domain}", actor.id) > 0
        redis.sadd("user_options:subscribe_tag:#{actor.acct}", tag)
        added_tags << tag
        count += 1
      end
    end
    {count, added_tags.first(20)}
  end

  def unsubscribe_tags(actor : Actor, tags : Array(String)) : {Int32, Array(String)}
    count = 0
    deleted_tags = [] of String
    tags.each do |tag|
      tag = tag.to_s.downcase
      if redis.srem("subscribe:#{tag}:#{actor.domain}", actor.id) > 0
        redis.srem("user_options:subscribe_tag:#{actor.acct}", tag)
        deleted_tags << tag
        count += 1
      end
    end
    {count, deleted_tags.first(20)}
  end

  def unsubscribe_all_tags(actor : Actor) : Int32
    tags = redis.smembers("user_options:subscribe_tag:#{actor.acct}")
    redis.del("user_options:subscribe_tag:#{actor.acct}")
    tags.each do |tag|
      tag = tag.to_s.downcase
      redis.srem("subscribe:#{tag}:#{actor.domain}", actor.id)
    end
    tags.size
  end

  def subscribe_accts(actor : Actor, accts : Array(String)) : {Int32, Array(String)}
    count = 0
    added_accts = [] of String
    accts.each do |acct|
      acct = "@#{acct}"
      if redis.sadd("subscribe:#{acct}:#{actor.domain}", actor.id) > 0
        redis.sadd("user_options:subscribe_acct:#{actor.acct}", acct)
        added_accts << acct
        count += 1
      end
    end
    {count, added_accts.first(20)}
  end

  def unsubscribe_accts(actor : Actor, accts : Array(String)) : {Int32, Array(String)}
    count = 0
    deleted_accts = [] of String
    accts.each do |acct|
      acct = "@#{acct}"
      if redis.srem("subscribe:#{acct}:#{actor.domain}", actor.id) > 0
        redis.srem("user_options:subscribe_acct:#{actor.acct}", acct)
        deleted_accts << acct
        count += 1
      end
    end
    {count, deleted_accts.first(20)}
  end

  def unsubscribe_all_accts(actor : Actor) : Int32
    accts = redis.smembers("user_options:subscribe_acct:#{actor.acct}")
    redis.del("user_options:subscribe_acct:#{actor.acct}")
    accts.each do |acct|
      redis.srem("subscribe:#{acct}:#{actor.domain}", actor.id)
    end
    accts.size
  end

  def fetch_mastodon_instance(domain) : Instance
    url = "https://#{domain}/api/v1/instance"
    headers = HTTP::Headers{"Accept" => "application/activity+json, application/ld+json"}
    response = HTTP::Client.get(url, headers: headers)
    unless response.status_code == 200
      error(400, "Got non-200 response from fetching #{url.inspect}")
    end
    Instance.from_json(response.body)
  end

  def fetch_pleroma_nodeinfo(domain) : Nodeinfo
    url = "https://#{domain}/nodeinfo/2.1.json"
    headers = HTTP::Headers{"Accept" => "application/activity+json, application/ld+json"}
    response = HTTP::Client.get(url, headers: headers)
    unless response.status_code == 200
      error(400, "Got non-200 response from fetching #{url.inspect}")
    end
    Nodeinfo.from_json(response.body)
  end

  def fetch_misskey_admin_users(domain) : Array(MisskeyUser)
    url = "https://#{domain}/api/users"
    headers = HTTP::Headers{"Accept" => "application/activity+json, application/ld+json", "Content-Type" => "application/json"}
    body = {state: "admin", limit: 100}.to_json
    response = HTTP::Client.post(url, headers: headers, body: body)
    unless response.status_code == 200
      error(400, "Got non-200 response from fetching #{url.inspect}")
    end
    Array(MisskeyUser).from_json(response.body)
  end

  def add_admin(domain, acct)
    redis.sadd("admin:#{domain}", acct)
  end

  def get_admins(domain)
    redis.smembers("admin:#{domain}").map(&.to_s)
  end

  def is_admin?(domain, acct)
    redis.sismember("admin:#{domain}", acct) == 1
  end

  def del_admin(domain, acct)
    redis.srem("admin:#{domain}", acct)
  end

  def del_all_admins(domain)
    redis.del("admin:#{domain}")
  end

  def follow?(actor)
    redis.hexists("connection:#{actor.domain}", actor.id) == 1
  end

  def server_subscription?(actor)
    redis.exists("subscription:#{actor.domain}") == 1
  end

  def user_subscription?(actor)
    redis.sismember("follower:actor", actor.id) == 1
  end

  def follow(actor)
    follow_id = PubRelay.route_url("/#{UUID.random}")
    redis.hset("connection:#{actor.domain}", actor.id, follow_id)

    follow_activity = {
      "@context": {"https://www.w3.org/ns/activitystreams"},

      id:     follow_id,
      type:   "Follow",
      actor:  PubRelay.route_url("/actor"),
      object: actor.id,
    }

    DeliverWorker.async.perform(actor.domain, follow_activity.to_json, PubRelay.route_url("/actor"))
  end

  def unfollow(actor)
    follow_id = redis.hget("connection:#{actor.domain}", actor.id)
    redis.hdel("connection:#{actor.domain}", actor.id)

    unfollow_activity = {
      "@context": {"https://www.w3.org/ns/activitystreams"},

      id:     PubRelay.route_url("/#{UUID.random}"),
      type:   "Undo",
      actor:  PubRelay.route_url("/actor"),
      object: {
        id:     follow_id,
        type:   "Follow",
        actor:  PubRelay.route_url("/actor"),
        object: actor.id,
      },
    }

    DeliverWorker.async.perform(actor.domain, unfollow_activity.to_json, PubRelay.route_url("/actor"))
  end

  def create_note(actor, message, in_reply_to = nil, json = false)
    record_id = "#{UUID.random}"
    create_note_activity = {
      "@context": {
        "https://www.w3.org/ns/activitystreams",
        "https://w3id.org/security/v1",
        {
          "manuallyApprovesFollowers": "as:manuallyApprovesFollowers",
          "sensitive":                 "as:sensitive",
          "movedTo":                   {
            "@id":   "as:movedTo",
            "@type": "@id",
          },
          "alsoKnownAs": {
            "@id":   "as:alsoKnownAs",
            "@type": "@id",
          },
          "Hashtag":          "as:Hashtag",
          "ostatus":          "http://ostatus.org#",
          "atomUri":          "ostatus:atomUri",
          "inReplyToAtomUri": "ostatus:inReplyToAtomUri",
          "conversation":     "ostatus:conversation",
          "toot":             "http://joinmastodon.org/ns#",
          "Emoji":            "toot:Emoji",
          "focalPoint":       {
            "@container": "@list",
            "@id":        "toot:focalPoint",
          },
          "featured": {
            "@id":   "toot:featured",
            "@type": "@id",
          },
          "schema":        "http://schema.org#",
          "PropertyValue": "schema:PropertyValue",
          "value":         "schema:value",
        },
      },
      id:        PubRelay.route_url("/users/controller/statuses/#{record_id}/activity"),
      type:      "Create",
      actor:     PubRelay.route_url("/controller"),
      published: Time.utc,
      to:        [
        actor.id,
      ],
      cc:     [] of String,
      object: {
        id:   PubRelay.route_url("/users/controller/statuses/#{record_id}"),
        type: "Note",
        to:   [
          actor.id,
          PubRelay.route_url("/controller/followers"),
        ],
        cc:           [] of String,
        inReplyTo:    in_reply_to,
        url:          PubRelay.route_url("/@relayctl/#{record_id}"),
        attributedTo: PubRelay.route_url("/controller"),
        content:      json ? message : %{<p><span class="h-card"><a href="#{actor.href}" class="u-url mention">@<span>#{actor.username}</span></a></span> #{message}</p>},
        tag:          [
          {
            href: actor.href,
            name: actor.acct,
            type: "Mention",
          },
        ],
      },
    }

    DeliverWorker.async.perform(actor.domain, create_note_activity.to_json, PubRelay.route_url("/controller"))
  end

  private def redis
    PubRelay.redis
  end
end

struct NamedTuple
  def to_mes
    io = IO::Memory.new
    to_mes(io)
    io.to_s
  end

  def to_mes(io)
    {% for key, value, i in T %}
      {% if i > 0 %}
        io << "<br>"
      {% end %}
      key = {{key.stringify}}
      io << I18n.translate(key: key) << ": "
      self[{{key.symbolize}}].to_mes(io)
    {% end %}
  end
end

class Array
  def to_mes(io)
    if self.size == 0
      io << "(#{I18n.translate(key: "none", default: "none")})"
    else
      first = true
      self.each do |value|
        io << " " unless first
        io << value.to_s
        first = false
      end
    end
  end
end

class String
  def to_mes(io)
    io << self.to_s
  end
end

struct Bool
  def to_mes(io)
    io << self.to_s
  end
end

struct Nil
  def to_mes(io)
    io << "(#{I18n.translate(key: "none", default: "none")})"
  end
end
