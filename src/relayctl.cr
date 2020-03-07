require "dotenv"
Dotenv.load

require "clim"
require "./i18n_helper"
require "./pub_relay"
require "./relay_activity"

I18n.load_path += ["./config/locales"]
I18n.init
I18n.default_locale = ENV["LANG"]?.to_s.split(/[_\.]/).first

include I18nHelper

module RelayCtl
  class Cli < Clim

    VERSION = "0.1.0"

    main do
      desc t("cli_desc")
      usage "relayctl [subcommand] [arguments] [options]"
      version "relayctl version #{VERSION}", short: "-v"
      help short: "-h"
      run do |opts, args|
        puts opts.help_string
      end

      sub "refresh" do
        desc t("cli_refresh_desc")
        usage "relayctl refresh USERNAME [options]"
        option "-d DOMAIN", "--domain=DOMAIN", type: String, desc: "Target domain.", default: ""
        run do |opts, args|
          unless args.size == 1
            puts opts.help_string
            return
          end

          domain = args[0].downcase
          RelayActor.update(domain, opts.domain)
        end
      end

      sub "publish" do
        desc t("cli_publish_desc")
        usage "relayctl publish activity.json [options]"
        option "-a ACTOR", "--actor=ACTOR", type: String, desc: "Target actor.", default: "actor"
        option "-d DOMAINS", "--domains=DOMAINS", type: Array(String), desc: "Target domains.", default: [] of String
        option "-t TO_ACTOR_ID", "--to=TO_ACTOR_ID", type: Array(String), desc: "TO target actors. (id or keyword: public, followers)", default: [] of String
        option "-c CC_ACTOR_ID", "--cc=CC_ACTOR_ID", type: Array(String), desc: "CC target actors. (id or keyword: public, followers)", default: [] of String
        option "-v VISIBILITY", "--visibility=VISIBILITY", type: String, desc: "Visibility. (keyword: public, unlisted, private, direct, nop)", default: "public"
        option "--object=OBJECT_ID", type: String, desc: "Target object ID.", default: ""
        run do |opts, args|
          unless args.size == 1
            puts opts.help_string
            return
          end

          unless Cli::VISIBILITY.includes? opts.visibility
            puts "#{opts.visibility} is invalid visibility. Please specify from the following. (public, unlisted, private, direct)"
            return
          end

          to, cc = Cli.apply_visibility(opts.actor, opts.to, opts.cc, opts.visibility)

          json = File.read(args[0]).gsub(/({{(?:.+?)}})/, {
            "{{root}}"   => PubRelay.route_url(""),
            "{{host}}"   => PubRelay.host,
            "{{actor}}"  => opts.actor,
            "{{object}}" => opts.object,
            "{{uuid}}"   => UUID.random,
            "{{to}}"     => to.to_json,
            "{{cc}}"     => cc.to_json,
          })
          puts json

          RelayActivity.publish(opts.domains || RelayActivity.subscription_domains, json, actor_id: PubRelay.route_url("/#{opts.actor}"))
        end
      end

      sub "delete" do
        desc "Delete activity from relay agent."
        usage "relayctl delete [options]"
        option "-i ACTIVITY_ID", "--activity_id=ACTIVITY_ID", type: String, desc: "Target activity ID.", default: ""
        option "-a ACTOR", "--actor=ACTOR", type: String, desc: "Target actor.", default: ""
        option "-d DOMAIN", "--domain=DOMAIN", type: String, desc: "Target domain.", default: ""
        run do |opts, args|
          unless args.size == 0 && (!opts.activity_id.empty? || !opts.actor.empty? || !opts.domain.empty?)
            puts opts.help_string
            return
          end

          if opts.activity_id.empty?
            puts "not impliment"
            puts opts.help_string
          else
            RelayActivity.delete(opts.activity_id)
          end
        end
      end
    end

    def self.replace_keyword(targets : Array(String), actor : String)
      targets.map do |target|
        case target
        when "public"
          "https://www.w3.org/ns/activitystreams#Public"
        when "followers"
          PubRelay.route_url("/#{actor}/followers")
        else
          target
        end
      end
    end

    VISIBILITY = %w(public unlisted private direct nop)

    def self.apply_visibility(actor : String, to : Array(String), cc : Array(String), visibility : String)
      to = Cli.replace_keyword(to, actor)
      cc = Cli.replace_keyword(cc, actor)
      public_id = "https://www.w3.org/ns/activitystreams#Public"
      followers_id = PubRelay.route_url("/#{actor}/followers")

      case visibility
      when "public"
        to = to.push(public_id).uniq
        cc = cc.reject(&.==(public_id))
      when "unlisted"
        to = to.reject(&.==(public_id))
        cc = cc.push(public_id).uniq
      when "private"
        to = to.reject(&.==(public_id)).push(followers_id).uniq
        cc = cc.reject(&.==(public_id))
      when "direct"
        to = to.reject(&.==(public_id)).reject(&.==(followers_id))
        cc = cc.reject(&.==(public_id)).reject(&.==(followers_id))
      end
      {to, cc}
    end
  end
end

RelayCtl::Cli.start(ARGV)
