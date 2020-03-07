require "toml"
require "./converters"

class Actor
  include JSON::Serializable

  getter id : String
  @[JSON::Field(key: "publicKey")]
  property public_key : Key
  getter endpoints : Endpoints?
  getter inbox : String
  @[JSON::Field(key: "type")]
  getter actor_type : String?
  getter preferredUsername : String?
  getter name : String?
  getter url : String?
  getter uri : String?

  @[JSON::Field(key: "alsoKnownAs", converter: FuzzyStringArrayConverter)]
  getter also_known_as : Array(String)?

  SUPPORTED_TYPES = {"Application", "Group", "Organization", "Person", "Service"}

  def initialize(@id, @public_key, @endpoints, @inbox)
  end

  def inbox_url
    endpoints.try(&.shared_inbox) || inbox
  end

  def domain
    URI::Punycode.to_ascii(URI.parse(id).host.not_nil!.strip.downcase)
  end

  def href
    url || id
  end

  def displayname
    if !name.to_s.blank?
      name
    else
      username
    end
  end

  def username
    preferredUsername || File.basename(URI.parse(id).path.not_nil!.strip.downcase)
  end

  def acct
    "@#{username}@#{domain}"
  end

  def pleroma_relay?
    name == "Pleroma" && actor_type == "Application" && username == "relay"
  end
end

struct Key
  include JSON::Serializable

  @[JSON::Field(key: "publicKeyPem")]
  getter public_key_pem : String
  getter owner : String

  def initialize(@public_key_pem : String, @owner)
  end
end

struct Endpoints
  include JSON::Serializable

  @[JSON::Field(key: "sharedInbox")]
  getter shared_inbox : String?
end

class RelayActor
  def self.update(actor, target = "")
    case actor
    when "actor"
      object = make_actor_activity
    when "controller"
      object = make_controller_activity
    else
      puts "Unknown USERNAME #{actor}"
      return
    end

    domains = (PubRelay.redis.keys("subscription:*") + PubRelay.redis.keys("connection:*")).compact_map do |key|
      prefix, domain = key.as(String).split(':', 2)
      domain
    end

    if !target.empty? && domains.includes? target
      domains = [target]
    end

    bulk_args = domains.uniq.compact_map do |domain|
      {domain, update_activity(actor, object).to_json, PubRelay.route_url("/#{actor}")}
    end

    DeliverWorker.async.perform_bulk(bulk_args)
  end

  def self.update_activity(actor, object)
    {
      "@context": "https://www.w3.org/ns/activitystreams",

      id:     PubRelay.route_url("/#{actor}#update/#{UUID.random}"),
      type:   "Update",
      actor:  PubRelay.route_url("/#{actor}"),
      object: object,
    }
  end

  def self.make_actor_activity
    TOML.parse(File.read(File.join(Dir.current, "config/actor.toml")).gsub(/({{(?:.+?)}})/, {
      "{{root}}" => PubRelay.route_url(""),
      "{{host}}" => PubRelay.host,
    })).as(Hash).merge({
      "@context"          => {"https://www.w3.org/ns/activitystreams", "https://w3id.org/security/v1"},
      "id"                => PubRelay.route_url("/actor"),
      "type"              => "Group",
      "preferredUsername" => "relay",
      "inbox"             => PubRelay.route_url("/inbox"),
      "followers"         => PubRelay.route_url("/actor/followers"),
      "publicKey"         => {
        id:           PubRelay.route_url("/actor#main-key"),
        owner:        PubRelay.route_url("/actor"),
        publicKeyPem: PubRelay.private_key.public_key.to_pem,
      },
    })
  end

  def self.make_controller_activity
    TOML.parse(File.read(File.join(Dir.current, "config/controller.toml")).gsub(/({{(?:.+?)}})/, {
      "{{root}}" => PubRelay.route_url(""),
      "{{host}}" => PubRelay.host,
    })).as(Hash).merge({
      "@context"          => {"https://www.w3.org/ns/activitystreams", "https://w3id.org/security/v1"},
      "id"                => PubRelay.route_url("/controller"),
      "type"              => "Service",
      "preferredUsername" => "relayctl",
      "inbox"             => PubRelay.route_url("/controller/inbox"),
      "followers"         => PubRelay.route_url("/controller/followers"),
      "publicKey"         => {
        id:           PubRelay.route_url("/controller#main-key"),
        owner:        PubRelay.route_url("/controller"),
        publicKeyPem: PubRelay.private_key.public_key.to_pem,
      },
    })
  end
end
