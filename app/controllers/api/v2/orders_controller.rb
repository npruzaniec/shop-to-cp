class Api::V2::OrdersController < Api::V2::ApiV2Controller
  defaults :resource_class => Order.api, :collection_name => 'orders', :instance_name => 'order'
  before_filter :api_authentication
  authorize_resource

  def show
    find
  end

  def update
    find
    @order.update(params[:order])
  end

  private

  def find_by_id_or_sku
    id = params[:id]
    @order = Order.find(id)
    return render_404("Could not find order with id or sku of #{params[:id]}") unless @order.present?
  end
end
