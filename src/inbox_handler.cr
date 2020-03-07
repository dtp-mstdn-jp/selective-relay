require "./signature_verification"
require "./activity"
require "./deliver_worker"
require "./inbox_worker"
require "./activity_filter"

class InboxHandler
  include SignatureVerification

  def handle
    request_body, actor_from_signature, key_id = verify_signature

    InboxWorker.async.perform(actor_from_signature, request_body, key_id)

    response.status_code = 202
    response.puts "OK"
  rescue ignored : SignatureVerification::Error
    # error output was already set
  end
end
