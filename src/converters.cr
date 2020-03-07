module PresenceConverter
  def self.from_json(pull) : Bool
    present = pull.kind != JSON::PullParser::Kind::Null
    pull.skip
    present
  end

  def self.to_json(value, json : JSON::Builder)
    json.bool value
  end
end

module FuzzyStringArrayConverter
  def self.from_json(pull) : Array(String)
    strings = Array(String).new

    case pull.kind
    when JSON::PullParser::Kind::BeginArray
      pull.read_array do
        if string = pull.read? String
          strings << string
        else
          pull.skip
        end
      end
    else
      strings << pull.read_string
    end

    strings
  end

  def self.to_json(value, json : JSON::Builder)
    json.array do
      value.each do |str|
        json.string str
      end
    end
  end
end

module HashConverter
  def self.from_json(pull) : Hash(String, String)
  end

  def self.to_json(value, json : JSON::Builder)
    json.field value.key, value.value
  end
end
