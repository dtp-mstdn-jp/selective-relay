require "dotenv"
Dotenv.load

require "./i18n_helper"
require "./pub_relay"

I18n.load_path += ["./config/locales"]
I18n.init

handlers = [] of HTTP::Handler
handlers << HTTP::LogHandler.new if ENV["RELAY_DEBUG"]?
handlers << Citrine::I18n::Handler.new
handlers << PubRelay.new

server = HTTP::Server.new(handlers)
bind_ip = server.bind_tcp(
  host: ENV["RELAY_HOST"]? || "localhost",
  port: (ENV["RELAY_PORT"]? || 8085).to_i,
  reuse_port: !!ENV["RELAY_REUSEPORT"]?
)

puts "Listening on #{bind_ip}"
server.listen
