class DeliverWorker
  include Sidekiq::Worker

  sidekiq_options do |job|
    job.retry = false
  end

  def perform(domain : String, request_body : String, key_id : String)
    inbox_url = PubRelay.redis.hget("subscription:#{domain}", "inbox_url") || PubRelay.redis.hget("connection:#{domain}", "inbox_url")
    return unless inbox_url
    inbox_url = URI.parse(inbox_url)

    body_hash = OpenSSL::Digest.new("sha256")
    body_hash.update(request_body)
    body_hash = Base64.strict_encode(body_hash.digest)

    headers = HTTP::Headers{
      "Host"   => inbox_url.host.not_nil!,
      "Date"   => HTTP.format_time(Time.utc),
      "Digest" => "SHA-256=#{body_hash}",
      "Content-Type" => "application/ld+json;profile=\"https://www.w3.org/ns/activitystreams\"",
      "User-Agent" => "selective-relay/0.1.0 (#{PubRelay.route_url("")})",
    }

    signed_headers = "(request-target) host date digest"
    signed_string = <<-END
      (request-target): post #{inbox_url.path}
      host: #{headers["Host"].downcase}
      date: #{headers["Date"]}
      digest: #{headers["Digest"]}
      END

    algorithm = "rsa-sha256"
    signature = PubRelay.private_key.sign(OpenSSL::Digest.new("sha256"), signed_string)

    headers["Signature"] = %(keyId="#{key_id}",algorithm="#{algorithm}",headers="#{signed_headers}",signature="#{Base64.strict_encode(signature)}")

    # RelayActivity.record_activity(request_body)

    client = HTTP::Client.new(inbox_url)
    client.dns_timeout = 10.seconds
    client.connect_timeout = 10.seconds
    client.read_timeout = 10.seconds
    response = client.post(inbox_url.full_path, headers: headers, body: request_body)
  rescue ex
    puts "POST #{inbox_url} #{ex.message}"
  else
    puts "POST #{inbox_url} #{response.status_code}"
  end
end
