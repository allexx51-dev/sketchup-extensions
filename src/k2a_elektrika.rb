# encoding: UTF-8
# Электрика (трассы) — загрузчик расширения SketchUp
require 'sketchup.rb'
require 'extensions.rb'

module K2A
  module Elektrika
    unless file_loaded?(__FILE__)
      ex = SketchupExtension.new('K2A Электрика (трассы)', 'k2a_elektrika/main')
      ex.description = 'Расстановка розеток, выключателей, светильников и щита; ' \
                       'автотрассы стена–потолок–стена; ручная правка; спецификация кабеля.'
      ex.version     = '0.5.1'
      ex.creator     = 'Алексей (allexx51-dev)'
      ex.copyright   = '© 2026 allexx51-dev · MIT'
      Sketchup.register_extension(ex, true)
      file_loaded(__FILE__)
    end
  end
end
