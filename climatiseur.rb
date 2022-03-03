#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

THRESHOLD = 2

class Climatiseur < ScannerBotBase
  no_commands do
    def main
      credentials = load_credentials

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
          next
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
      if thermostat == 'heat' && (outdoor_temperature - indoor_temperature > THRESHOLD) && open.length.zero?
        subject = "It's warmer outside, please open some more doors and windows"
        message = (['You might open one of these:'] + closed).join("\n")
      elsif thermostat == 'heat' && (outdoor_temperature - indoor_temperature < -THRESHOLD) && !open.length.zero?
        subject = "Close the doors!  It's cold outside!"
        message = "Why would you have the #{open.join(' & ')} open?"
      elsif thermostat == 'cool' && (outdoor_temperature - indoor_temperature > THRESHOLD) && !open.length.zero?
        subject = "Close the doors!  It's hot outside!"
        message = "Why would you have the #{open.join(' & ')} open?"
      elsif thermostat == 'cool' && (outdoor_temperature - indoor_temperature < -THRESHOLD) && open.length.zero?
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
    end
  end
end

Climatiseur.start
