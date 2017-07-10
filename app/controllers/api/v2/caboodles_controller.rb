class Api::V2::CaboodlesController < Api::V2::ApiV2Controller
  defaults :resource_class => Caboodle.api, :collection_name => 'caboodles', :instance_name => 'caboodle'
  load_and_authorize_resource
end