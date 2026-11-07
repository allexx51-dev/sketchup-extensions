# encoding: UTF-8
require 'sketchup.rb'
require 'extensions.rb'

module K2A
  module Profile
    EXT = SketchupExtension.new('K2A Профиль по линиям', 'k2a_profile/main')
    EXT.version     = '1.7.0'
    EXT.creator     = 'Алексей (allexx51-dev)'
    EXT.copyright   = '© 2026 allexx51-dev · MIT'
    EXT.description = 'Квадратный/прямоугольный профиль нулевой толщины по выделенным рёбрам.'
    Sketchup.register_extension(EXT, true)
  end
end
