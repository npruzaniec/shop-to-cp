class Api::V1::OrdersController < Api::V1::BaseController

  # We will need to switch the order API to use HTTP auth, like we do for counterpoint, once we start using it.

  %w{index update destroy}.each do |action|
    define_method(action) { raise AbstractController::ActionNotFound }
  end

  def show
    @order = Order.find(params[:id])
    respond_with(@order.to_json(only: [:id, :state, :created_at], methods: [:subtotal, :total]), :location => api_v1_order_path(@order))
  end

  def create
    order = Order.create_via_api(params[:order], current_user)
    if order.errors.none? && order.valid?
      respond_with(order.to_json(only: [:id, :state, :created_at], methods: [:subtotal, :total]), :location => api_v1_order_path(order))
    else
      respond_with(order)
    end
  end

end
