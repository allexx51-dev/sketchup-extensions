# encoding: UTF-8
require 'sketchup.rb'
require 'extensions.rb'

module K2A
  module AngleDim
    EXT = SketchupExtension.new('K2A Угловой размер', 'k2a_angledim/main')
    EXT.version     = '1.3.0'
    EXT.creator     = 'Алексей (allexx51-dev)'
    EXT.copyright   = '© 2026 allexx51-dev · MIT'
    EXT.description = 'Угловой размер: вершина, две стороны, положение дуги.'
    Sketchup.register_extension(EXT, true)
  end
end
