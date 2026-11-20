# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module K2A
  module SolarPlanner
    unless file_loaded?(__FILE__)
      ex = SketchupExtension.new('K2A Солнечные панели', 'k2a_solar/main')
      ex.description = 'Расстановка солнечных панелей на скаты крыши, плоскую кровлю и землю: обход дымоходов и препятствий, зазор между рядами по солнцу, профиль, прижимы, балласт и спецификация.'
      ex.version     = '1.11.2'
      ex.creator     = 'Алексей (allexx51-dev)'
      ex.copyright   = '© 2026 allexx51-dev · MIT'
      Sketchup.register_extension(ex, true)
      file_loaded(__FILE__)
    end
  end
end
