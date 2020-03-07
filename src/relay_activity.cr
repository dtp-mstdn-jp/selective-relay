class RelayActivity
  def self.delete(activity_id : String)
    if md = activity_id.match(%r(^#{PubRelay.route_url("/users")}/(.+?)[/#].+$))
      actor = md[1]
      RelayActivity.publish(RelayActivity.connection_domains, RelayActivity.delete_activity(actor, activity_id).to_json, PubRelay.route_url("/#{actor}"))
    elsif md = activity_id.match(%r(^#{PubRelay.route_url("")}/@(.+?)[/#].+$))
      case md[1]
      when "relay"
        actor = "actor"
      when "relayctl"
        actor = "controller"
      else
        return
      end
      RelayActivity.publish(RelayActivity.connection_domains, RelayActivity.delete_activity(actor, activity_id).to_json, PubRelay.route_url("/#{actor}"))
    else
    end
  end

  def self.delete_activity(actor, object)
    {
      "@context": {"https://www.w3.org/ns/activitystreams"},

      id:     PubRelay.route_url("/#{actor}/#delete/#{UUID.random}"),
      type:   "Delete",
      actor:  PubRelay.route_url("/#{actor}"),
      object: object,
    }
  end

  def self.connection_domains
    (PubRelay.redis.keys("subscription:*") + PubRelay.redis.keys("connection:*")).compact_map do |key|
      prefix, domain = key.as(String).split(':', 2)
      domain
    end
  end

  def self.subscription_domains
    PubRelay.redis.keys("subscription:*").compact_map do |key|
      prefix, domain = key.as(String).split(':', 2)
      domain
    end
  end

  def self.publish(domains : Array(String), activity_json : String, actor_id : String)
    bulk_args = domains.uniq.compact_map do |domain|
      {domain, activity_json, actor_id}
    end
    DeliverWorker.async.perform_bulk(bulk_args)
  end

  def self.record_activity(request_body)
    request = JSON.parse(request_body)
    ap_id = request["id"]?.to_s
    if !ap_id.empty? && ap_id.starts_with?(PubRelay.route_url(""))
      PubRelay.redis.hset("activity", ap_id, request_body)
      ap_url = request["url"]?.to_s
      PubRelay.redis.hset("redirect", ap_url, ap_id) if !ap_url.empty?

      unless request["object"] == String
        object_id = request["object"]["id"]?.to_s if request["object"]
        if object_id && !object_id.empty? && object_id.starts_with?(PubRelay.route_url(""))
          PubRelay.redis.hset("activity", object_id, request["object"].to_json)
          object_url = request["object"]["url"]?.to_s
          PubRelay.redis.hset("redirect", object_url, object_id) if !object_url.empty?
        end
      end
    end
  end
end
