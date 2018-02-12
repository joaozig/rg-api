class V1::Client::HighlightsController < ApplicationController

  def index
    highlights = ['teste 1', 'teste 2']
    render json: highlights
  end
end