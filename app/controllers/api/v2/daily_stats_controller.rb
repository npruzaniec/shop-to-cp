class Api::V2::DailyStatsController < Api::V2::ApiV2Controller
  defaults :resource_class => DailyStat.api, :collection_name => 'daily_stats', :instance_name => 'daily_stat'
  before_filter :api_authentication
  authorize_resource

  def show
    find_by_id_or_date
  end

  def update
    find_by_id_or_date
    @daily_stat.update(params[:daily_stat])
  end

  private

  def find_by_id_or_date
    id = params[:id]
    if id.to_s.include? "date"
      @daily_stat = DailyStat.where("date = ?",id.to_s.sub("date:","")).first
    else
      @daily_stat = DailyStat.find(params[:id])
    end
    return render_404("Could not find daily with id or date of #{params[:id]}") unless @daily_stat.present?
  end

end
