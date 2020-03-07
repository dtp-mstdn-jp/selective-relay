class InboxWorker
  include Sidekiq::Worker

  sidekiq_options do |job|
    job.retry = false
  end

  def perform(actor_from_signature : Actor, request_body : String, key_id : String)
    activity = Activity.from_json(request_body)
    activity.object = Activity::Object.from_json(fetch_object(activity.object_id_string.not_nil!)) if activity.announce?

    case activity
    when .follow?
      handle_follow(actor_from_signature, activity)
    when .unfollow?
      handle_unfollow(actor_from_signature, activity)
    when .valid_for_rebroadcast?
      handle_update(actor_from_signature, activity, key_id) if activity.update?
      handle_forward(actor_from_signature, activity, request_body)
    end
  rescue ex
    puts "exception(inbox) #{ex.message}"
  end

  private def fetch_object(url : String) : String
    headers = HTTP::Headers{"Accept" => "application/activity+json, application/ld+json"}
    response = HTTP::Client.get(url, headers: headers)
    unless response.status_code == 200
      PubRelay.logger.info "Got non-200 response from fetching #{url.inspect}"
      raise Exception.new
    end
    response.body
  end

  private def handle_follow(actor, activity)
    if activity.object_is_public_collection?
      PubRelay.redis.hset("subscription:#{actor.domain}", "inbox_url", actor.inbox_url)
    elsif actor.pleroma_relay?
      PubRelay.redis.hset("subscription:#{actor.domain}", "inbox_url", actor.inbox_url)
      follow(actor)
    else
      PubRelay.redis.sadd("follower:actor", actor.id )
    end

    accept_activity = {
      "@context": {"https://www.w3.org/ns/activitystreams"},

      id:     PubRelay.route_url("/actor#accepts/follows/#{actor.domain}"),
      type:   "Accept",
      actor:  PubRelay.route_url("/actor"),
      object: {
        id:     activity.id,
        type:   "Follow",
        actor:  actor.id,
        object: PubRelay.route_url("/actor"),
      },
    }

    DeliverWorker.async.perform(actor.domain, accept_activity.to_json, PubRelay.route_url("/actor"))
  end

  private def handle_unfollow(actor, activity)
    if activity.object_is_public_collection? || actor.pleroma_relay?
      PubRelay.redis.del("subscription:#{actor.domain}")
    else
      PubRelay.redis.srem("follower:actor", actor.id )
    end
  end

  private def handle_update(actor, activity, key_id)
    if activity.object_types.any? { |type| Actor::SUPPORTED_TYPES.includes? type } && activity.object_id_string == actor.id
      remote_actor_key = "remote_actor:cache:#{key_id}"
      if PubRelay.redis.exists(remote_actor_key) == 1
        PubRelay.redis.del(remote_actor_key)
        puts "delete cache: #{remote_actor_key}"
      end

      remote_actor_key = "remote_actor:cache:#{actor.public_key.owner}"
      if PubRelay.redis.exists(remote_actor_key) == 1
        PubRelay.redis.del(remote_actor_key)
        puts "delete cache: #{remote_actor_key}"
      end
    end
  end

  private def handle_forward(actor, activity, request_body)
    # TODO: cache the subscriptions
    filter = ActivityFilter.new(actor, activity)

    subscription_domains = PubRelay.redis.keys("subscription:*").compact_map(&.as(String).lchop("subscription:"))
    bulk_args = subscription_domains.compact_map do |domain|
      filter.domain = domain

      if domain == actor.domain || filter.reject_delivery?
        nil
      else
        if !activity.signature_present? && activity.note?
          {domain, announce(activity).to_json, PubRelay.route_url("/actor")}
        else
          {domain, request_body, PubRelay.route_url("/actor")}
        end
      end
    end

    DeliverWorker.async.perform_bulk(bulk_args)

    domains = [] of String
    if (tags = activity.hashtag_names)
      tags.each do |tag|
        domains += PubRelay.redis.keys("subscribe:#{tag}:*").compact_map do |key|
          prefix, _tag, domain = key.as(String).split(':', 3)
          domain
        end
      end
    end
    domains += PubRelay.redis.keys("subscribe:#{actor.acct}:*").compact_map do |key|
      prefix, _acct, domain = key.as(String).split(':', 3)
      domain
    end

    bulk_args = [] of Tuple(String, String, String)
    domains.uniq.each do |domain|
      filter.domain = domain
      next if filter.reject_subscribe_delivery?

      target_actors = [] of String
      if tags
        tags.each do |tag|
          target_actors += PubRelay.redis.sinter("subscribe:#{tag}:#{domain}", "follower:actor")
        end
      end
      target_actors += PubRelay.redis.sinter("subscribe:#{actor.acct}:#{domain}", "follower:actor")
      target_actors.reject(&.==(actor.id)).uniq

      if activity.note?
        while target_actors.size > 0
          bulk_args << {domain, announce(activity, target_actors.shift(20)).to_json, PubRelay.route_url("/actor")}
        end
      elsif !(domain == actor.domain || subscription_domains.includes?(domain) || filter.reject_delivery?)
        bulk_args << {domain, request_body, PubRelay.route_url("/actor")}
      end
    end

    DeliverWorker.async.perform_bulk(bulk_args)
  end

  private def follow(actor)
    follow_id = PubRelay.route_url("/#{UUID.random}")
    PubRelay.redis.hset("connection:#{actor.domain}", actor.id, follow_id)

    follow_activity = {
      "@context": {"https://www.w3.org/ns/activitystreams"},

      id:     follow_id,
      type:   "Follow",
      actor:  PubRelay.route_url("/actor"),
      object: actor.id,
    }

    DeliverWorker.async.perform(actor.domain, follow_activity.to_json, PubRelay.route_url("/actor"))
  end

  private def announce(activity : Activity, to = [] of String)
    annouce_activity = {
      "@context": {"https://www.w3.org/ns/activitystreams"},

      id:     PubRelay.route_url("/actor#announce/#{UUID.random}"),
      type:   "Announce",
      actor:  PubRelay.route_url("/actor"),
      object: activity.object_id_string,
      to:     ["https://www.w3.org/ns/activitystreams#Public"] + to,
      published: Time.utc,
    }
  end
end
