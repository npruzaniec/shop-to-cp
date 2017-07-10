class Api::V2::AuthorsController < Api::V2::ApiV2Controller
  defaults :resource_class => Author.api, :collection_name => 'authors', :instance_name => 'author'
  load_and_authorize_resource
end
