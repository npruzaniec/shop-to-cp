class Api::V1::CounterpointController < ActionController::Base

  protect_from_forgery except: :create
  require 'json'
  require 'csv'

  before_filter :http_auth unless Rails.env == "test"

  %w{show update destroy}.each do |action|
    define_method(action) { raise AbstractController::ActionNotFound }
  end

  def http_auth
    authenticate_or_request_with_http_basic do |username, password|
      # puts "*************************** u=#{username} p=#{password} *************************************"
      if Rails.env.production?
        username == ENV['COUNTERPOINT_API_ID'] && password == ENV['COUNTERPOINT_API_PASSWORD']
      else
        username == "counterpointSALEZ" && password == "jlhsdjghldgh"
      end
    end
  end

  def index
    # url is /api/v1/counterpoint.json
    respond_to do |format|
      #format.json { render json: JSON.pretty_generate(Counterpoint.build_completed_orders_counterpoint_feed) }
      puts JSON.pretty_generate(Counterpoint.build_completed_orders_counterpoint_feed)
      format.json { render json: Counterpoint.build_completed_orders_counterpoint_feed }
    end
  end

  def create
    puts "*************************** CREATE *************************************"
    puts params.inspect
    #1st parameter contains the csv file information
    # uploaded_csv = params.first[1] #params[:filename]
    uploaded_csv = params[:filename]

    puts uploaded_csv.inspect
    if uploaded_csv.nil?
      render text: "NO DATA"
    else
      response = Counterpoint.import_counterpoint_csv_from_file(uploaded_csv.tempfile)
      render text: response
    end
    puts request.raw_post.inspect
  end

  def settlement
    # url is /api/v1/counterpoint/settlement
    # this method receives a json list of order ids and then returns a json object of settled_at dates
    # sample json input: ["46","45"]
    render json: Counterpoint.build_settle_date_for_orders(JSON.parse(params[:orders]))
  end
end
