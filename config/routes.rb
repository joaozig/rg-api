Rails.application.routes.draw do

  namespace :v1 do

    namespace :client do
      resources :sessions, only: [:create, :destroy]
    end
  end
end
