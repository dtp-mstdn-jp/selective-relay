class Nodeinfo
  include JSON::Serializable

  getter metadata : Metadata?
end

struct Metadata
  include JSON::Serializable

  @[JSON::Field(key: "staffAccounts")]
  getter staff_accounts : Array(String)?
end
