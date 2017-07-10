class Api::V2::VariantsController < Api::V2::ApiV2Controller
  defaults :resource_class => Variant.api, :collection_name => 'variants', :instance_name => 'variant'
  before_filter :api_authentication
  authorize_resource

  def show
    find_by_id_or_sku
  end

  def update
    find_by_id_or_sku
    @variant.update(params[:variant])
  end

  def index
    if params[:filter]
      if params[:filter] == "tracked"
        @variants = Variant.where("tracked = ?",true)
      end
    else
      super
    end
  end

  private

  def find_by_id_or_sku
    id = params[:id]
    if id.to_s.include? "sku"
      @variant = Variant.where("sku in (?)",[(id.to_s.sub("sku:","")),(id.to_s.sub("sku:","").to_i - 100000).to_s]).first
    else
      @variant = Variant.find(params[:id])
    end
    return render_404("Could not find variant with id or sku of #{params[:id]}") unless @variant.present?
  end

end
