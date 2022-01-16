#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
require 'fileutils'
require 'influxdb'
require 'logger'
require 'mail'
require 'thor'
require 'yaml'
require 'time'

LOGFILE = File.join(Dir.home, '.log', 'climatiseur.log')
CREDENTIALS_PATH = File.join(Dir.home, '.credentials', 'climatiseur.yaml')

class Climatiseur < Thor
  no_commands do
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), mode: 0o755)
        FileUtils.touch logfile
        File.chmod 0o644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def setup_logger
      redirect_output if options[:log]

      @logger = Logger.new $stdout
      @logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      @logger.info 'starting'
    end
  end

  class_option :log,     type: :boolean, default: true, desc: "log output to #{LOGFILE}"
  class_option :verbose, type: :boolean, aliases: '-v', desc: 'increase verbosity'

  desc 'scan', ''
  method_option :dry_run, type: :boolean, aliases: '-n', desc: "don't send notifications"
  def scan
    setup_logger

    credentials = YAML.load_file CREDENTIALS_PATH

    Mail.defaults do
      delivery_method :smtp, credentials[:mail_delivery_defaults]
    end

    nest = InfluxDB::Client.new(database: 'nest', host: 'cube.local', precison: 'ms')
    wxdata = InfluxDB::Client.new(database: 'wxdata', host: 'cube.local', precison: 'ms')
    frontpoint = InfluxDB::Client.new(database: 'frontpoint', host: 'cube.local', precison: 'ms')

    #
    # determine heating/cooling (thermostat) status
    #

    result = nest.query "select last(value) from hvac_mode where name_long = 'Family Room Thermostat'"
    family_room = result[0]['values'][0]['last']
    if Time.now - Time.parse(result[0]['values'][0]['time']) > 5000
      @logger.error "'Family Room Thermostat' measurement is stale"
      return
    end
    result = nest.query "select last(value) from hvac_mode where name_long = 'Living Room Thermostat'"
    if Time.now - Time.parse(result[0]['values'][0]['time']) > 5000
      @logger.error "'Living Room Thermostat' measurement is stale"
      return
    end
    living_room = result[0]['values'][0]['last']

    thermostat = family_room
    if thermostat != living_room && !(family_room == 'eco' || living_room == 'eco')
      @logger.error "'Living Room Thermostat' measurement is stale"
      return
    end
    @logger.info "thermostat set to '#{thermostat}'"

    #
    # determine indoor/outdoor temperatures
    #

    result = wxdata.query 'select last(value) from temperature_indoor'
    if Time.now - Time.parse(result[0]['values'][0]['time']) > 5000
      @logger.error 'indoor temperature measurement is stale'
      return
    end
    indoor_temperature = result[0]['values'][0]['last']
    @logger.info "indoor temperature is #{indoor_temperature}"

    result = wxdata.query 'select last(value) from temperature_outdoor'
    if Time.now - Time.parse(result[0]['values'][0]['time']) > 5000
      @logger.error 'outdoor temperature measurement is stale'
      return
    end
    outdoor_temperature = result[0]['values'][0]['last']
    @logger.info "outdoor temperature is #{outdoor_temperature}"

    #
    # determine state of portals
    #

    closed = []
    open = []
    result = frontpoint.query 'select last(value) from state group by description'
    result.each do |sensor|
      description = sensor['tags']['description']
      next unless credentials[:portals].include? description

      if Time.now - Time.parse(sensor['values'][0]['time']) > 5000
        @logger.error "'#{description}' sensor measurement is stale"
        return
      end
      closed.push description if sensor['values'][0]['last'].zero?
      open.push description if sensor['values'][0]['last'] == 1
    end
    @logger.info "closed (#{closed.length}) #{closed}"
    @logger.info "open (#{open.length}) #{open} "

    # send alert if indoors and outdoors are incorrectly balanced
    #  - we're heating and it's hotter outside and portals are closed
    #  - we're heating and it's colder outside and portals are open
    #  - we're cooling and it's hotter outside and portals are open
    #  - we're cooling and it's colder outside and portals are closed
    subject = nil
    message = nil
    if thermostat == 'heat' && (outdoor_temperature > indoor_temperature) && open.length.zero?
      subject = "It's warmer outside, please open some more doors and windows"
      message = (['You might open one of these:'] + closed).join("\n")
    elsif thermostat == 'heat' && (outdoor_temperature < indoor_temperature) && !open.length.zero?
      subject = "Close the doors!  It's cold outside!"
      message = "Why would you have the #{open.join(' & ')} open?"
    elsif thermostat == 'cool' && (outdoor_temperature > indoor_temperature) && !open.length.zero?
      subject = "Close the doors!  It's hot outside!"
      message = "Why would you have the #{open.join(' & ')} open?"
    elsif thermostat == 'cool' && (outdoor_temperature < indoor_temperature) && open.length.zero
      subject = "It's cooler outside, please open some more doors and windows"
      message = (['You might open one of these:'] + closed).join("\n")
    end
    if subject && message
      @logger.info subject
      @logger.info message
      unless options[:dry_run]
        credentials[:notify].each do |email|
          Mail.deliver do
            to email
            from credentials[:sender]
            subject subject
            body message
          end
        end
      end
    else
      @logger.info "all's well!"
    end
  rescue StandardError => e
    @logger.error e
  end

  default_task :scan
end

Climatiseur.start
