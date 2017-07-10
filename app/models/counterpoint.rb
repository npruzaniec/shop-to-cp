class Counterpoint
  require 'csv'

  def self.build_completed_orders_counterpoint_feed
    # get all competed orders not posted to counterpoint - order.counterpoint_order_id = nil
    limit = 100
    limit = ENV['COUNTERPOINT_API_LIMIT_OVERRIDE'].to_i if ENV['COUNTERPOINT_API_LIMIT_OVERRIDE'].to_i > 0
    completed_but_not_posted_orders = Order.completed.not_posted_to_counterpoint.limit(limit)

    begin
      if ENV['COUNTERPOINT_INVENTORY_CUTOFF_DATE'].present?
        parsed_date = Chronic.parse(ENV['COUNTERPOINT_INVENTORY_CUTOFF_DATE'])
        if parsed_date.nil?
          raise "Invalid date specified for COUNTERPOINT_INVENTORY_CUTOFF_DATE"
        end
        completed_but_not_posted_orders = completed_but_not_posted_orders.before_inventory_cutoff(parsed_date)
      end
    rescue Exception => e
      # raises the ACTUAL error for the developer for troubleshooting
      puts "Error:  #{e.message} (Full stack backtrace)"
      e.backtrace.each { |line| puts line }
      puts "Error:  #{e.message} (Application backtrace)"
      e.backtrace.select { |line| line.starts_with?(Rails.root.to_s) }.each { |line| puts line } # Only show application backtrace

      Airbrake.notify(e, {error_message: e.message})
      return [e.message]
    end

    completed_but_not_posted_orders_feed = Array.new

    # loop though completed but not posted orders and build feed for each order
    completed_but_not_posted_orders.each do |order|

      begin
        order_feed = order_to_feed_data(order)

        Counterpoint.audit_order(order_feed, order)

        completed_but_not_posted_orders_feed << order_feed
      rescue Exception => e
        # raises the ACTUAL error for the developer for troubleshooting
        puts "Error:  #{e.message} (Full stack backtrace)"
        e.backtrace.each { |line| puts line }
        puts "Error:  #{e.message} (Application backtrace)"
        e.backtrace.select { |line| line.starts_with?(Rails.root.to_s) }.each { |line| puts line } # Only show application backtrace

        Airbrake.notify(e, {error_message: "Counterpoint Export Error Order ##{order.id}: #{e.message}"})
        order.counterpoint_order_id = -1
        order.save!(:validate => false)
      end

    end

    number_of_completed_but_not_posted_orders = completed_but_not_posted_orders.count
    # ap "NUMBER OF ORDERS TO BE POSTED: #{number_of_completed_but_not_posted_orders}"

    total_amount_of_completed_but_not_posted_orders = completed_but_not_posted_orders.map(&:total).sum
    # ap "TOTAL AMOUNT OF ORDERS TO BE POSTED: #{total_amount_of_completed_but_not_posted_orders}"

    posted_orders = {order_count: number_of_completed_but_not_posted_orders, order_total: total_amount_of_completed_but_not_posted_orders,
                     orders: completed_but_not_posted_orders_feed}

    # ap "************** POSTED ORDER FEED"
    # ap posted_orders
    # ap "************** POSTED ORDER FEED"

    #File.write(Rails.root.join('log', 'Counterpoint Export '+Time.zone.now.strftime("%Y-%m-%d_%H-%M-%S-%L")+'.json'), JSON.pretty_generate(posted_orders))
    posted_orders #.to_json
  end

  def self.order_to_feed_data(order)
    {order_id: order.id,
     submitted_at: order.submitted_at,
     user_id: order.user_id,
     type: Counterpoint.get_source_type(order),
     shipping_amount: Counterpoint.get_shipping_amount(order),
     subtotal: order.subtotal,
     shipping_carrier: Counterpoint.get_shipping_carrier(order),
     shipping_method: Counterpoint.get_shipping_method(order),
     handling: Counterpoint.get_handling_amount(order),
     ca_sales_tax: Counterpoint.get_tax_amount(order),
     total: order.total,
     shipping: Counterpoint.get_shipping_address(order),
     billing: Counterpoint.get_billing_info(order),
     payments: Counterpoint.get_payment_info(order),
     lines: Counterpoint.get_line_info(order).empty? ? nil : Counterpoint.get_line_info(order),
     comments: Counterpoint.get_comment_info(order),
     affiliate: Counterpoint.get_affiliate(order)}
  end

  def self.audit_order(order_feed, order)
    lines_total = 0.to_money
    order_feed_discount_total = 0.to_money
    unless order_feed[:lines].nil?
      order_feed[:lines].each do |line|
        lines_total += line[:total].to_f
        order_feed_discount_total += line[:discount_amount].to_f if line[:discount_amount]
      end
    end

    order_discount_total = 0.to_money
    order.lines_valid.each do |line|
      order_discount_total += (line.price.to_f - line.adjusted_price.to_f)
    end

    if order_feed_discount_total != order_discount_total
      raise "For Order #{order.id}, calculated discount total of #{order_feed_discount_total} does not equal order discount total of #{order_discount_total}"
    end

    payments_total = 0.to_money
    gift_total = 0.to_money
    unless order_feed[:payments].nil?
      order_feed[:payments].each do |payment|
        if payment[:source] == "gift_voucher"
          gift_total += (payment[:amount].to_f * -1)
        else
          payments_total += payment[:amount].to_f
        end
      end
    end
    payments_total = payments_total
    gift_total = gift_total

    subtotal = order_feed[:subtotal].to_f.to_money
    shipping_amount = order_feed[:shipping_amount].to_f.to_money
    handling = order_feed[:handling].to_f.to_money
    ca_sales_tax = order_feed[:ca_sales_tax].to_f.to_money
    total = order_feed[:total].to_f.to_money

    calculated_total = lines_total + shipping_amount + handling + ca_sales_tax + gift_total

    if calculated_total != order.total
      raise "For Order #{order.id}, calculated total of #{calculated_total} does not equal order total of #{order.total}"
    end

  end

  def self.reset_orders_posted_to_counterpoint
    completed_and_posted_orders = Order.completed.posted_to_counterpoint

    completed_and_posted_orders.each do |order|
      order.counterpoint_order_id = nil
      order.save!
    end

    completed_but_not_posted_orders = Order.completed.not_posted_to_counterpoint
    # ap "NUMBER OF RESET ORDERS: #{completed_but_not_posted_orders.count}"
  end

  def self.reset_first_order_posted_to_counterpoint
    order = Order.completed.posted_to_counterpoint.first
    order.counterpoint_order_id = nil
    order.save!
  end

  def self.import_counterpoint_csv_from_file(filename)
    csv_text = File.read(filename)
    # puts "*************************** CSV_FILE *************************************"
    # puts csv_text

    csv = CSV.parse(csv_text, :headers => false)

    import_csv(csv)
  end

  def self.import_csv(csv)
    record_count = 0
    error_count = 0
    # data[0] = bethel_id, data[1] = counterpoint_id, data[2] = total
    csv.each do |data|
      record_count += 1
      error_message = nil
      order = Order.find_by_id(data[0])

      if order && !order.counterpoint_order_id
        if data[2].to_money == order.total
          Counterpoint.process_order(order, data[1])
        else
          error_message = "Total for order #{order.id} did not match counterpoint order #{data[1]}"
        end
      else
        if order && order.counterpoint_order_id
          error_message = "Order #{data[0]} has already been processed"
        else
          error_message = "Could not find order #{data[0]}"
        end
      end

      if error_message
        error_count += 1
        puts error_message
        Airbrake.notify(Exception.new(error_message))
      end
    end

    "Processed #{record_count} orders and had #{error_count} errors with the data."
  end

  def self.process_order(order, counterpoint_id)
    order.counterpoint_posted_at = Time.zone.now
    order.counterpoint_order_id = counterpoint_id
    order.save!(:validate => false)
    # ap order
    puts "Order #{order.id} was processed"
  end

  # I think this is supposed to be Complete? That's what it is in the old store
  # Any orders that we are sending through should be a complete status so this can just be complete
  def self.get_source_type(order)
    "Complete"
  end

  def self.get_shipping_amount(order)
    return nil unless order.physical_items? || order.refund?
    return nil unless order.shipping_adjustment.present? && order.shipping_adjustment.amount.present?
    order.shipping_adjustment.amount - order.shipping_adjustment.handling
  end

  # United Parcel Service or United States Postal Service
  def self.get_shipping_carrier(order)
    return nil if Counterpoint.get_shipping_method(order).nil?
    carrier = nil
    if Counterpoint.get_shipping_method(order).match(/UPS/)
      carrier = "United Parcel Service"
    elsif Counterpoint.get_shipping_method(order).match(/USPS/)
      carrier = "United States Postal Service"
    end
    carrier
  end

  # this is supposed to show something like:
  # First-Class Mail
  def self.get_shipping_method(order)
    return nil unless order.physical_items? || order.refund?
    return nil if order.shipping_method_id.nil?
    ShippingMethod.find_by_id(order.shipping_method_id).name
  end

  def self.get_handling_amount(order)
    return nil unless order.physical_items? || order.refund?
    return nil unless order.shipping_adjustment.present? && order.shipping_adjustment.amount.present?
    order.shipping_adjustment.handling
  end

  def self.get_tax_amount(order)
    return nil unless order.tax_adjustment.present?
    order.tax_adjustment.amount
  end

  def self.get_shipping_address(order)
    if order.shipping_address.present?
      shipping_address = {
        name: order.shipping_address.full_name,
        company: order.shipping_address.company,
        # This is a temporary workaround for https://www.pivotaltracker.com/story/show/66548592
        # Once the issue is fixed in counterpoint, we can revert it back to the way it was.
        address_1: [order.shipping_address.address_1, order.shipping_address.address_2].join(' '),
        address_2: nil,
        city: order.shipping_address.city,
        state: order.shipping_address.state,
        postal_code: order.shipping_address.postal_code,
        country: order.shipping_address.country_name,
        phone: order.shipping_address.phone,
        email: order.user.email}
    else
      shipping_address = {
        name: nil,
        company: nil,
        address_1: nil,
        address_2: nil,
        city: nil,
        state: nil,
        postal_code: nil,
        country: nil,
        phone: nil,
        email: order.user.email}
    end
    shipping_address
  end

  def self.get_billing_info(order)
    if order.payments.any?
      billing_info = {name: order.payments.first.cardholder_name,
                      company: order.payments.first.company,
                      address_1: order.payments.first.street_address,
                      address_2: order.payments.first.extended_address,
                      city: order.payments.first.locality,
                      state: order.payments.first.region,
                      postal_code: order.payments.first.postal_code,
                      country_code: order.payments.first.country_code_alpha2}
    else
      billing_info = {name: nil,
                      company: nil,
                      address_1: nil,
                      address_2: nil,
                      city: nil,
                      state: nil,
                      postal_code: nil,
                      country_code: nil}
    end
    billing_info
  end

  def self.get_payment_info(order)
    return nil unless order.payments.any? || order.gift_adjustments.any?
    payment_info = Array.new
    order.payments.each do |payment|
      payment_info << {id: payment.id,
                       description: payment.counterpoint_description,
                       amount: payment.amount,
                       source: payment.source,
                       source_type: payment.source_type,
                       source_created_at: payment.source_created_at,
                       source_trans_id: payment.transaction_id,
                       card_bin: payment.card_bin,
                       card_last_4: payment.card_last_4,
                       card_type: payment.card_type}
    end

    order.gift_adjustments.each do |gift|
      payment_info << {id: gift.id,
                       description: gift.description,
                       amount: gift.amount * -1, #gift card amounts are stored as negative in the store db but need to go to counterpoint as positive
                       source: "gift_voucher",
                       source_type: "sale",
                       source_created_at: gift.created_at,
                       source_trans_id: gift.adjuster_id}
    end

    payment_info
  end

  def self.get_line_info(order)
    line_info = Array.new
    order.lines_valid.each do |line|
      variant = Variant.find_by_id(line.variant_id)
      # sends counterpoint bundled items individually instead of the main product
      if variant.counterpoint_send_bundled_items_individually?
        variant.variants.each_with_index do |bundled_variant, index|
          # put prices on first line only, set prices for other lines to 0
          if index > 0
            line_price = 0.to_money
            line_adjusted_price = 0.to_money
            line_total = 0.to_money
          else
            line_price = line.price
            line_adjusted_price = line.adjusted_price
            line_total = line.total
          end

          this_line_info = {id: line.id,
                            sku: bundled_variant.sku,
                            title: "#{bundled_variant.product.title} | #{bundled_variant.name} (#{bundled_variant.product_format.name})",
                            quantity: line.quantity,
                            price: line_price,
                            adjusted_price: line_adjusted_price,
                            total: line_total,
                            taxable: bundled_variant.kind.taxable?,
                            type: bundled_variant.kind.owner[:kind],
                            weight: line.weight}

          # Only apply discounts to first line
          if line.get_active_discount.any? && index == 0
            discount_info = Counterpoint.get_line_discount(line.get_active_discount.first)
            this_line_info.merge!(discount_info)
          end

          line_info << this_line_info
        end
      else
        this_line_info = get_line_information(line, variant)

        # even though a line can have many adjustments, it will only have one active adjustment that represents the largest discount
        if line.get_active_discount.any?
          discount_info = Counterpoint.get_line_discount(line.get_active_discount.first)
          this_line_info.merge!(discount_info)
        end

        line_info << this_line_info
      end
    end

    line_info
  end

  def self.get_line_information(line, variant)
    {id: line.id,
     sku: variant.sku,
     title: "#{variant.product.title} | #{variant.name} (#{variant.product_format.name})",
     quantity: line.quantity,
     price: line.price,
     adjusted_price: line.adjusted_price,
     total: line.total,
     taxable: variant.kind.taxable?,
     type: variant.kind.owner[:kind],
     weight: line.weight}
  end

  def self.get_line_discount(discount)
    {discount_amount: discount.amount.to_money,
     discount_description: discount.description,
     discount_id: discount.id}
  end

  def self.get_comment_info(order)
    return "" if order.special_instructions.nil?
    order.special_instructions
  end

  def self.get_affiliate(order)
    return nil if order.vendor.nil?
    {id: order.vendor.id,
     name: order.vendor.name}
  end

  def self.reset_order_posted_to_counterpoint(order)
    order.counterpoint_order_id = nil
    order.save!
  end

  def self.build_settle_date_for_orders(ids)
    settled_info = Array.new
    ids.each do |id|
      message = ''
      settled_on = ''
      order = Order.find_by_id(id)

      #gracefully handle invalid orders and payments and populate the message accordingly
      if !order
        message = 'Error: Invalid order id'
      elsif !order.payments[0]
        message = "Error: No payment for order"
      elsif !order.payments[0].settled_on
        message = "Error: Order has not been settled"
      else
        settled_on = order.payments[0].settled_on
      end

      settled_info_line = {id: id,
                           settled_on: settled_on,
                           message: message}
      settled_info << settled_info_line
    end
    settled_info
  end
end
