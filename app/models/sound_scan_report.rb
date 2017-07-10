# == Schema Information
#
# Table name: sound_scan_reports
#
#  id          :integer          not null, primary key
#  vendor_id   :integer
#  starting_at :datetime
#  ending_at   :datetime
#  delivered   :boolean          default(FALSE), not null
#  data        :text
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#

require 'net/ftp'
require 'stringio'

class SoundScanReport < ActiveRecord::Base
  include ReportingUtilities

  attr_accessible :data, :delivered, :ending_at, :starting_at, :vendor_id

  belongs_to :vendor

  default_scope { order("id ASC") }

  # quick way to update tracks in "Come Away" seed data
  # mp3s = Variant.joins { product_format }.where { (product_id == 200) & (product_format.name == 'MP3') }.readonly(false)
  # mp3s.each { |variant| variant.upc = '796745102924'; variant.isrc = "TRACK_#{variant.number}"; variant.sound_scan_reporting = true; variant.sound_scan_album = false; variant.save! }


  ##############################################################################
  #                                CLASS METHODS                               #
  ##############################################################################
  class << self
    def build_reports(debug = false)
      raise "Invalid debug option." if debug && !debug.in?([:send_now, :dont_send])
      end_at = Chronic.parse('last Thursday at 23:59:59')
      start_at = end_at - 1.week

      data = {}

      Order.where(:state => 'complete', :submitted_at => start_at..end_at).find_each do |order|
        zip = ReportingUtilities::valid_zip(order.united_states_zip_code) || next
        order.lines_valid.each do |line|
          begin
            variant = line.variant
            vendor = variant.vendor
            if variant.sound_scan_reporting?
              unless vendor.sound_scan_chain_number.present? && vendor.sound_scan_account.present?
                raise "Vendor (id=#{vendor.id}, #{vendor.name}) missing SoundScan info"
              end
              if variant.sound_scan_album?
                upc = ReportingUtilities::valid_upc(line.variant.upc) || next
                isrc = ''
                type_desc = 'A'
              else
                upc = ''
                isrc = variant.isrc
                type_desc = 'S'
              end
              strata = 'P'
              unless data[vendor.id]
                data[vendor.id] = {chain_number: vendor.sound_scan_chain_number,
                                   account: vendor.sound_scan_account,
                                   records: [],
                                   transactions_sent: 0,
                                   net_units_sold: 0}
              end
              data[vendor.id][:net_units_sold] += line.quantity

              line.quantity.abs.times do |n|
                data[vendor.id][:transactions_sent] += 1
                price = "%04d" % [(line.adjusted_price*100).to_f.round] # 4 digits, no decimals
                # Ensure UPC is numeric...because there was bad data :(
                data[vendor.id][:records] << "D3|#{upc}|#{zip}|#{(line.quantity > 0 ? 'S' : 'R')}|#{n+1}|#{isrc}|#{price}|#{type_desc}|#{strata}"
              end
            end
          rescue Exception => e
            # raises the ACTUAL error for the developer for troubleshooting
            puts "Error:  #{e.message} (Full stack backtrace)"
            e.backtrace.each { |line| puts line }
            puts "Error:  #{e.message} (Application backtrace)"
            e.backtrace.select { |line| line.starts_with?(Rails.root.to_s) }.each { |line| puts line } # Only show application backtrace

            Airbrake.notify(e, {error_message: "SoundScan Export Error line.id #{line.id}: #{e.message}"})
          end
        end
      end

      # Add header/footer data to each record and save
      data.each do |vendor_id, vendor_data|

        # If for some reason the report has already been built, we shouldn't rebuild it
        next if self.where(:vendor_id => vendor_id, :starting_at => start_at, :ending_at => end_at).count > 0

        # Add the header, which must start with 92, and then have the vendor's
        # sound_scan_chain_number, sound_scan_account and then end with the date in YYMMDD format.  No 'pipes' for the header.
        vendor_data[:records].unshift("92#{vendor_data[:chain_number]}#{vendor_data[:account]}#{end_at.strftime("%y%m%d")}")

        # Add the footer, which must start with 94, then have the total number
        # of transactions , then end with the net number
        # of units sold
        vendor_data[:records] << "94|%d|%d" % [vendor_data[:transactions_sent], vendor_data[:net_units_sold]]

        # Store the data record to be processed/delivered
        report = self.create!(:vendor_id => vendor_id,
                              :starting_at => start_at,
                              :ending_at => end_at,
                              :data => vendor_data[:records].join("\n")
        )
        puts "-"*80
        puts report.data
        puts "-"*80

        if debug == :send_now
          report.upload_data
        end
      end
      self.deliver_reports unless debug
    end

    handle_asynchronously :build_reports, :queue => 'reporting', :priority => 1 # High priority, as this is time sensitive

    def deliver_reports
      undelivered_reports = self.where(:delivered => false)

      undelivered_reports.each do |report|
        report.delay.upload_data
      end
    end

    handle_asynchronously :deliver_reports, :queue => 'reporting', :priority => 1 # High priority, as this is time sensitive

    def build_and_deliver_reports
      SlackNotifier.scheduled_jobs("build and deliver sound scan report") do
        if Time.zone.now.friday?
          self.build_reports
        else
          raise 'This command should only be run once on Friday mornings.'
        end
      end
    end
  end

  ##############################################################################
  #                              INSTANCE METHODS                              #
  ##############################################################################

  # Upload undelivered data to the FTP site
  def upload_data
    Net::FTP.open("retail.vnureig.com") do |ftp|
      ftp.login(ENV['SOUND_SCAN_LOGIN'], ENV['SOUND_SCAN_PASSWORD'])

      f = StringIO.new(data)
      begin
        filename = "#{vendor.sound_scan_chain_number}_#{vendor.sound_scan_account}_#{ending_at.strftime("%y%m%d")}_#{vendor.id}.txt"
        puts "Uploading #{filename} via FTP..."
        ftp.storlines("STOR #{filename}", f)
      ensure
        puts ftp.last_response
        rc = ftp.last_response_code
        puts "Response code = #{rc}"
        ftp.close
      end

      if rc == "200"
        self.delivered = true
        self.save!
      end
    end
  end

  # Net::FTP.open("retail.vnureig.com") { |ftp| ftp.login(ENV['SOUND_SCAN_LOGIN'], ENV['SOUND_SCAN_PASSWORD']); ap ftp.list }

end
