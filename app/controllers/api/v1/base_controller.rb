class Api::V1::BaseController < ActionController::Base
  
  respond_to :json
  before_filter :authenticate_user
  
  unless %w(development alpha).include?(Rails.env)
    rescue_from Exception, with: :render_500
    rescue_from ActionController::RoutingError, with: :render_404
    rescue_from ActionController::UnknownController, with: :render_404
    rescue_from AbstractController::ActionNotFound, with: :render_404
    rescue_from ActiveRecord::RecordNotFound, with: :render_404
  end
  
  protected
  
  def render_404
    respond_to do |format|
      format.json { render json: {error: "The API method does not exist"}, status: 404 }
    end
  end
  
  def render_500(exception)
    respond_to do |format|
      format.json { render json: {error: "Something went wrong.  Please check your input against the API docs and try again later"}, status: 500 }
    end
  end
  
  def authenticate_user
    @current_user = User.find_by_authentication_token_and_api_access(params[:token], true)
    unless @current_user
      respond_with({:error => "Token is invalid."}, :location => nil, :status => 401)
    end
  end

  def current_user
    @current_user
  end

end