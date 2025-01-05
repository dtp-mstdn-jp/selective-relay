require "uri"
require "lexbor"
require "./converters"

class Activity
  include JSON::Serializable

  getter id : String?
  getter actor : String?
  property object : String | Object
  getter published : Time?
  getter target : String?

  @[JSON::Field(key: "type", converter: FuzzyStringArrayConverter)]
  getter types : Array(String)

  @[JSON::Field(key: "signature", converter: PresenceConverter)]
  getter? signature_present = false

  @[JSON::Field(converter: FuzzyStringArrayConverter)]
  getter to = [] of String

  @[JSON::Field(converter: FuzzyStringArrayConverter)]
  getter cc = [] of String

  def follow?
    types.includes?("Follow")
  end

  def unfollow?
    types.includes?("Undo") && object.as?(Object).try &.types.includes?("Follow")
  end

  def note?
    case object
    in String
      types.includes?("Announce")
    in Object
      types.includes?("Create") && object.as?(Object).try &.types.includes?("Note")
    end
  end

  def announce?
    types.includes? "Announce"
  end

  def move?
    types.includes? "Move"
  end

  def update?
    types.includes? "Update"
  end

  PUBLIC_COLLECTION = "https://www.w3.org/ns/activitystreams#Public"

  def object_is_public_collection?(object = @object)
    case object
    when String
      object == PUBLIC_COLLECTION
    when Object
      case object.object
      when Nil
        false
      else
        object_is_public_collection? object.object
      end
    end
  end

  def addressed_to_public?
    to.includes?(PUBLIC_COLLECTION) || cc.includes?(PUBLIC_COLLECTION)
  end

  def object_id_string
    case object = @object
    when String
      object.not_nil!.to_s
    when Object
      object.id.not_nil!.to_s
    end
  end

  def object_types
    case object = @object
    when Object
      object.types
    else
      [] of String
    end
  end

  def content : String?
    object.as?(Object).try &.content
  end

  def content_text : String
    Lexbor::Parser.new(content.to_s)
      .nodes(:_text)
      .select(&.parents.all?(&.displayble?))
      .map(&.tag_text)
      .join("")
  end

  def attachments
    object.as?(Object).try &.attachments.as?(Array(Attachment)) || [] of Attachment
  end

  @_hashtag_names : Array(String)?

  def hashtag_names : Array(String)
    @_hashtag_names ||= ((object.as?(Object).try &.tags.as?(Array(Tag))) || [] of Tag).compact_map do |tag|
      tag.name.to_s.downcase if tag.type == "Hashtag"
    end.uniq
  end

  def subscribed?
    host = URI.parse(actor || "").host
    PubRelay.redis.exists("subscription:#{host}") == 1 || PubRelay.redis.exists("connection:#{host}") == 1
  end

  def actor_blocked?
    PubRelay.redis.exists("blocked_actor:#{actor}") == 1
  end

  VALID_TYPES = {"Create", "Update", "Delete", "Announce", "Undo", "Move"}

  def valid_for_rebroadcast?
    subscribed? && !actor_blocked? && addressed_to_public? && types.any? { |type| VALID_TYPES.includes? type }
  end

  def lang : String?
    object.as?(Object).try &.content_maps.try &.first_key?
  end

  class Object
    include JSON::Serializable

    getter id : String?
    property object : String | Object | Nil

    getter uri : String?

    @[JSON::Field(key: "type", converter: FuzzyStringArrayConverter)]
    getter types : Array(String)

    @[JSON::Field(key: "attachment")]
    getter attachments : Array(Attachment)?

    @[JSON::Field(key: "tag")]
    getter tags : Array(Tag)?

    getter content : String?

    @[JSON::Field(key: "contentMap")]
    getter content_maps : Hash(String, String)?
  end

  struct Attachment
    include JSON::Serializable

    getter type : String?
    getter mediatype : String?
    getter url : String?
    getter name : String?
  end

  struct Tag
    include JSON::Serializable

    getter type : String?
    getter href : String?
    getter name : String?
  end
end

struct Lexbor::Node
  def displayble?
    visible? && !object? && !is_tag_noindex?
  end
end
