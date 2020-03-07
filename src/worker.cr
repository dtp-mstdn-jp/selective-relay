require "dotenv"
Dotenv.load

require "sidekiq/cli"
require "./i18n_helper"
require "./pub_relay"

I18n.load_path += ["./config/locales"]
I18n.init

cli = Sidekiq::CLI.new
server = cli.create
cli.run(server)
