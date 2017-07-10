class Api::V2::ApiV2Controller < InheritedResources::Base
  actions :index, :show
  respond_to :json

  def api_authentication
    # in the rare case another use is signed in
    if current_user.present?
      sign_out current_user
    end
    authenticate_or_request_with_http_token do |token, opts|
      if user = User.authenticate_for_api(token)
        sign_in(:user, user, store: false)
      else
        false
      end
    end
  end

  protected

  def render_404(message = "The API method does not exist")
    respond_to do |format|
      format.json { render json: {error: message}, status: 404 }
    end
  end

  def render_401(message = "The API method does not exist")
    respond_to do |format|
      format.json { render json: {error: message}, status: 401 }
    end
  end

  rescue_from CanCan::AccessDenied do |exception|
    render_401(exception.action.to_s + exception.message + current_user.inspect.to_s)
  end

end
