# encoding: UTF-8
# K2A Электрика (трассы) v0.5.1 — SketchUp 2021+ (Ruby 2.7)
# Ключи данных 'ak_elektrika*' (атрибуты модели и настройки SketchUp) оставлены прежними:
# по ним находятся механизмы и трассы в уже сделанных моделях.
#
# Механизмы — компоненты в корне модели, словарь атрибутов 'ak_elektrika'.
# Трасса — группа рёбер в корне модели (тег ЭЛ_Трассы). Источник истины — точки
# в атрибуте 'pts' (мм). Если рёбра правили штатным «Перемещением», точки
# подхватываются из геометрии при следующей операции.

require 'sketchup.rb'
require 'json'
require File.join(File.dirname(__FILE__), 'route_math')

module K2A
  module Elektrika

    VERSION   = '0.5.1'.freeze
    DICT      = 'ak_elektrika'.freeze
    SDICT     = 'ak_elektrika_settings'.freeze
    TAG_DEV   = 'ЭЛ_Устройства'.freeze
    TAG_ROUTE = 'ЭЛ_Трассы'.freeze
    ICON_DIR  = File.join(File.dirname(__FILE__), 'icons')
    RM        = RouteMath

    # h — высота центра от чистого пола, мм; top — выход кабеля вверх от центра, мм
    # w/hz — полуширина/полувысота лицевой части, мм; ceil — можно ставить на потолок
    # group — подменю и панель; old — прежние имена определений (для замены вида)
    TYPES = {
      'socket'  => { name: 'Розетка',                 prefix: 'Р',  h: 300,  top: 35, w: 35, hz: 35, group: :sockets, color: [40, 110, 220], old: ['ЭЛ Розетка', 'ЭЛ Розетка v2'] },
      'socket3' => { name: 'Розетка трёхфазная',      prefix: 'Р',  h: 300,  top: 45, w: 45, hz: 45, group: :sockets, color: [170, 30, 30], cable: 'ВВГнг-LS 5×2,5' },
      'rj45'    => { name: 'Розетка RJ-45',           prefix: 'RJ', h: 300,  top: 35, w: 35, hz: 35, group: :sockets, color: [120, 120, 135], cable: 'UTP 5e' },
      'outlet'  => { name: 'Кабельвывод силовой',     prefix: 'КВ', h: 600,  top: 35, w: 35, hz: 35, group: :sockets, color: [120, 70, 160] },
      'switch'  => { name: 'Выключатель 1-клавишный', prefix: 'В',  h: 900,  top: 35, w: 35, hz: 35, group: :switches, color: [230, 90, 40], keys: 1, old: ['ЭЛ Выключатель', 'ЭЛ Выключатель v2'] },
      'switch2' => { name: 'Выключатель 2-клавишный', prefix: 'В',  h: 900,  top: 35, w: 35, hz: 35, group: :switches, color: [230, 90, 40], keys: 2 },
      'switch3' => { name: 'Выключатель 3-клавишный', prefix: 'В',  h: 900,  top: 35, w: 35, hz: 35, group: :switches, color: [230, 90, 40], keys: 3 },
      'pass'    => { name: 'Переключатель проходной', prefix: 'В',  h: 900,  top: 35, w: 35, hz: 35, group: :switches, color: [235, 160, 20], keys: 1, marks: 1 },
      'cross'   => { name: 'Переключатель перекрёстный', prefix: 'В', h: 900, top: 35, w: 35, hz: 35, group: :switches, color: [200, 50, 90], keys: 1, marks: 2 },
      'button'  => { name: 'Кнопка',                  prefix: 'К',  h: 900,  top: 35, w: 35, hz: 35, group: :switches, color: [40, 160, 90] },
      'light'   => { name: 'Светильник',              prefix: 'С',  h: 2000, top: 60, w: 60, hz: 60, group: :light, color: [255, 200, 40], ceil: true, old: ['ЭЛ Светильник', 'ЭЛ Светильник v2'] },
      'bra'     => { name: 'Вывод под бра',           prefix: 'БР', h: 1700, top: 25, w: 25, hz: 25, group: :light, color: [200, 150, 0] },
      'led'     => { name: 'Вывод под LED-ленту',     prefix: 'Л',  h: 2550, top: 15, w: 20, hz: 15, group: :light, color: [0, 180, 200], ceil: true },
      'panel'   => { name: 'Щит',                     prefix: 'Щ',  h: 1600, top: 200, w: 150, hz: 200, group: :panel, color: [110, 110, 110], old: ['ЭЛ Щит', 'ЭЛ Щит v2'] }
    }.freeze
    # Механизмы серии 71 мм — встают в блок под общую рамку
    BLOCKABLE = %w[socket rj45 outlet switch switch2 switch3 pass cross button].freeze
    GROUPS = { sockets: 'Розетки и выводы', switches: 'Выключатели и кнопки', light: 'Свет', panel: 'Щит' }.freeze
    DEF_VER = 'v3'.freeze

    CABLES = [
      ['ВВГнг-LS 3×1,5', [235, 190, 0]],
      ['ВВГнг-LS 3×2,5', [0, 170, 80]],
      ['ВВГнг-LS 3×4',   [240, 120, 0]],
      ['ВВГнг-LS 3×6',   [220, 30, 30]],
      ['ВВГнг-LS 3×10',  [150, 20, 20]],
      ['ВВГнг-LS 5×2,5', [30, 90, 220]],
      ['ВВГнг-LS 5×4',   [20, 50, 160]],
      ['ВВГнг-LS 2×1,5', [150, 90, 200]],
      ['UTP 5e',         [90, 90, 90]]
    ].freeze

    DEFAULTS = {
      'floor_z'   => 0.0,    # отметка чистого пола, мм
      'ceiling_h' => 2700.0, # высота до потолка, мм
      'offset'    => 10.0,   # отступ трассы от стены/потолка, мм
      'lane_step' => 20.0,   # разнос соседних трасс, мм
      'pitch'     => 71.0,   # шаг механизмов в блоке, мм
      'snap'      => 120.0,  # радиус прилипания к соседнему механизму, мм
      'zap_end'   => 200.0,  # запас у механизма, мм
      'zap_panel' => 500.0,  # запас у щита, мм
      'grid'      => 10.0,   # шаг сдвига сегмента при правке, мм
      'ceil_mode' => 'ortho' # ortho | direct
    }.freeze

    @last_cable = CABLES[1][0]
    @last_group = 'гр.1'
    @tcache  = {}
    @queue   = {}
    @added   = []
    @timer   = nil
    @atimer  = nil
    @busy    = false
    @undoing = false

    # ================= настройки и служебное =================

    def self.setting(key)
      v = Sketchup.active_model.get_attribute(SDICT, key)
      v.nil? ? DEFAULTS[key] : v
    end

    def self.set_setting(key, value)
      Sketchup.active_model.set_attribute(SDICT, key, value)
    end

    def self.sf(key)
      setting(key).to_f
    end

    def self.log_error(where, e)
      puts "[Электрика] #{where}: #{e.class}: #{e.message}\n#{(e.backtrace || [])[0, 6].join("\n")}"
    end

    def self.tag(name)
      m = Sketchup.active_model
      m.layers[name] || m.layers.add(name)
    end

    def self.material(name, rgb)
      mats = Sketchup.active_model.materials
      mat = mats[name]
      unless mat
        mat = mats.add(name)
        mat.color = Sketchup::Color.new(*rgb)
      end
      mat
    end

    def self.cable_material(cable)
      rec = CABLES.find { |c| c[0] == cable }
      material("ЭЛ_каб #{cable}", rec ? rec[1] : [128, 128, 128])
    end

    def self.next_id(type)
      m = Sketchup.active_model
      key = "cnt_p_#{tinfo(type)[:prefix]}" # общая нумерация по префиксу (все выключатели — В1, В2…)
      n = (m.get_attribute(SDICT, key) || 0).to_i
      ids = devices.map { |d| d.get_attribute(DICT, 'id') }
      loop do
        n += 1
        break unless ids.include?("#{tinfo(type)[:prefix]}#{n}")
      end
      m.set_attribute(SDICT, key, n)
      "#{tinfo(type)[:prefix]}#{n}"
    end

    def self.next_block_id
      m = Sketchup.active_model
      n = (m.get_attribute(SDICT, 'cnt_block') || 0).to_i + 1
      m.set_attribute(SDICT, 'cnt_block', n)
      "Б#{n}"
    end

    def self.num_s(v)
      format('%.2f', v).tr('.', ',')
    end

    def self.vec(v, len)
      Geom::Vector3d.new(v.x * len, v.y * len, v.z * len)
    end

    def self.hnorm(v)
      h = Geom::Vector3d.new(v.x, v.y, 0)
      h.length > 1e-9 ? h.normalize : h
    end

    # ================= геометрия механизмов =================
    # Локальные оси: +Y — от поверхности в помещение, X — вдоль стены, Z — вверх.

    def self.box(ents, x0, x1, y0, y1, z0, z1)
      pts = [[x0, y0, z0], [x1, y0, z0], [x1, y0, z1], [x0, y0, z1]].map do |p|
        Geom::Point3d.new(p.map(&:mm))
      end
      f = ents.add_face(pts)
      h = (y1 - y0).mm
      f.normal.y > 0 ? f.pushpull(h) : f.pushpull(-h)
    end

    def self.cylinder(ents, r, depth)
      f = ents.add_face(ents.add_circle(ORIGIN, Y_AXIS, r.mm, 24))
      h = depth.mm
      f.normal.y > 0 ? f.pushpull(h) : f.pushpull(-h)
    end

    WHITE = [240, 240, 238].freeze
    DARK  = [40, 40, 45].freeze

    def self.paint(ents, rgb)
      mat = material(format('ЭЛ_цв_%02x%02x%02x', *rgb), rgb)
      ents.grep(Sketchup::Face).each do |f|
        f.material = mat
        f.back_material = mat
      end
    end

    # Деталь-коробка в отдельной группе (детали не слипаются геометрией)
    def self.part(ents, x0, x1, y0, y1, z0, z1, rgb)
      g = ents.add_group
      box(g.entities, x0, x1, y0, y1, z0, z1)
      paint(g.entities, rgb)
      g
    end

    # Деталь-цилиндр, ось вдоль Y (от стены), центр (cx, cz)
    def self.part_cyl(ents, cx, cz, r, y0, y1, rgb)
      g = ents.add_group
      c = Geom::Point3d.new(cx.mm, y0.mm, cz.mm)
      f = g.entities.add_face(g.entities.add_circle(c, Y_AXIS, r.mm, 24))
      h = (y1 - y0).mm
      f.normal.y > 0 ? f.pushpull(h) : f.pushpull(-h)
      paint(g.entities, rgb)
      g
    end

    def self.keys(ents, n, y0)
      gap = 2
      w = (60.0 - gap * (n - 1)) / n
      n.times do |i|
        x0 = -30 + i * (w + gap)
        part(ents, x0, x0 + w, y0, y0 + 4, -30, 30, WHITE)
      end
    end

    def self.build_device(ents, type)
      t = tinfo(type)
      c = t[:color]
      case type
      when 'socket'
        part(ents, -35, 35, 0, 14, -35, 35, c)
        part_cyl(ents, 0, 0, 25, 14, 17, WHITE)
        [-9.5, 9.5].each { |x| part_cyl(ents, x, 0, 2.5, 17, 18, DARK) }
      when 'socket3'
        part(ents, -45, 45, 0, 20, -45, 45, c)
        part_cyl(ents, 0, 0, 34, 20, 23, WHITE)
        [[0, 18], [-17, 6], [17, 6], [-11, -15], [11, -15]].each { |x, z| part_cyl(ents, x, z, 3, 23, 24, DARK) }
      when 'rj45'
        part(ents, -35, 35, 0, 12, -35, 35, c)
        part(ents, -8, 8, 12, 14, -7, 7, DARK)
      when 'outlet'
        part(ents, -35, 35, 0, 12, -35, 35, c)
        part_cyl(ents, 0, 0, 10, 12, 22, DARK)
      when 'switch', 'switch2', 'switch3', 'pass', 'cross'
        part(ents, -35, 35, 0, 10, -35, 35, c)
        keys(ents, t[:keys], 10)
        (t[:marks] || 0).times do |i|
          x = t[:marks] == 1 ? 0 : (i.zero? ? -8 : 8)
          part(ents, x - 3, x + 3, 14, 15, 18, 24, DARK)
        end
      when 'button'
        part(ents, -35, 35, 0, 10, -35, 35, c)
        part_cyl(ents, 0, 0, 13, 10, 16, WHITE)
      when 'bra'
        part(ents, -25, 25, 0, 12, -25, 25, c)
        part_cyl(ents, 0, 0, 8, 12, 30, DARK)
      when 'led'
        part(ents, -20, 20, 0, 12, -15, 15, c)
        part(ents, -15, 15, 12, 14, -3, 3, DARK)
      when 'light'
        part_cyl(ents, 0, 0, 60, 0, 35, c)
      when 'panel'
        part(ents, -150, 150, 0, 120, -200, 200, c)
        part(ents, -120, 120, 120, 122, -170, 170, [150, 150, 150])
      end
    end

    def self.definition(type)
      m = Sketchup.active_model
      t = tinfo(type)
      dname = t[:custom] ? "ЭЛ #{t[:name]} [#{type} r#{t[:rev].to_i}]" : "ЭЛ #{t[:name]} #{DEF_VER}"
      d = m.definitions[dname]
      return d if d && d.valid? && d.entities.size > 0
      d = m.definitions.add(dname)
      if t[:custom]
        build_custom(d.entities, t)
      else
        build_device(d.entities, type)
      end
      # прежние определения этого типа — заменить на новый вид
      olds = (t[:old] || []).map { |n| m.definitions[n] }
      olds += m.definitions.select { |x| x.name.include?("[#{type} r") } if t[:custom]
      olds.compact.uniq.each do |od|
        next if od == d || !od.valid?
        od.instances.each { |i| i.definition = d if i.get_attribute(DICT, 'type') == type }
      end
      d
    end

    # ================= свои устройства =================
    # Библиотека — в настройках SketchUp (общая для всех моделей) и копией в модели,
    # чтобы модель открывалась на другом компьютере.

    FALLBACK = { name: 'Устройство', prefix: 'У', h: 900, top: 35, w: 35, hz: 35, color: [150, 150, 150] }.freeze
    FACES = { '+Y' => 'лицом по зелёной +Y', '-Y' => 'лицом по зелёной −Y', '+X' => 'лицом по красной +X',
              '-X' => 'лицом по красной −X', '+Z' => 'лицом вверх (по синей +Z)' }.freeze

    def self.sym_hash(h)
      h.each_with_object({}) { |(k, v), o| o[k.to_sym] = v }
    end

    def self.read_lib(json)
      return {} if json.to_s.empty?
      data = JSON.parse(json.to_s)
      data.is_a?(Hash) ? data.transform_values { |v| sym_hash(v) } : {}
    rescue StandardError
      {}
    end

    def self.user_lib
      read_lib(Sketchup.read_default('ak_elektrika', 'custom_types', ''))
    end

    def self.model_lib(model = Sketchup.active_model)
      read_lib(model.get_attribute(SDICT, 'custom_types'))
    end

    def self.save_user_lib(lib)
      Sketchup.write_default('ak_elektrika', 'custom_types', JSON.generate(lib))
    end

    def self.save_model_type(key, t)
      m = Sketchup.active_model
      lib = model_lib(m)
      lib[key] = t
      m.set_attribute(SDICT, 'custom_types', JSON.generate(lib))
    end

    def self.custom_lib
      model_lib.merge(user_lib)
    end

    def self.normalize_custom(t)
      t = FALLBACK.merge(t)
      t[:custom] = true
      t[:top] = t[:shape] == 'round' ? t[:w].to_f : t[:hz].to_f
      t[:ceil] = !!t[:ceil]
      t[:block] = !!t[:block]
      t
    end

    def self.tinfo(type)
      return TYPES[type] if TYPES.key?(type)
      t = custom_lib[type]
      t ? normalize_custom(t) : FALLBACK
    end

    def self.blockable?(type)
      BLOCKABLE.include?(type) || (!TYPES.key?(type) && tinfo(type)[:block])
    end

    def self.hex_rgb(hex)
      h = hex.to_s.delete('#')
      h.size == 6 ? [h[0, 2], h[2, 2], h[4, 2]].map { |x| x.to_i(16) } : FALLBACK[:color]
    end

    # Надпись (префикс) на лицевой грани: текст в плоскости XZ, читается с +Y
    def self.face_label(ents, text, y, size)
      return if text.to_s.empty?
      g = ents.add_group
      g.entities.add_3d_text(text, TextAlignCenter, 'Arial', true, false, size.mm, 0.0, 0.0, true, 0.6.mm)
      b = g.bounds
      g.transform!(Geom::Transformation.translation([-b.center.x, -b.center.y, 0]))
      g.transform!(Geom::Transformation.rotation(ORIGIN, X_AXIS, 90.degrees))
      g.transform!(Geom::Transformation.rotation(ORIGIN, Z_AXIS, 180.degrees)) # читается из помещения
      g.transform!(Geom::Transformation.translation([0, y.mm, 0]))
      paint(g.entities, DARK)
    rescue StandardError => e
      log_error('face_label', e)
    end

    # Поворот компонента пользователя лицом в +Y и его габарит после поворота
    def self.wrap_frame(cdef, face)
      rot = case face
            when '-Y' then Geom::Transformation.rotation(ORIGIN, Z_AXIS, 180.degrees)
            when '+X' then Geom::Transformation.rotation(ORIGIN, Z_AXIS, 90.degrees)
            when '-X' then Geom::Transformation.rotation(ORIGIN, Z_AXIS, -90.degrees)
            when '+Z' then Geom::Transformation.rotation(ORIGIN, X_AXIS, -90.degrees)
            else Geom::Transformation.new
            end
      bb = Geom::BoundingBox.new
      b = cdef.bounds
      8.times { |i| bb.add(b.corner(i).transform(rot)) }
      [rot, bb]
    end

    # Обёртка над компонентом пользователя: центр по X/Z, задняя грань на Y=0
    def self.wrap_component(ents, cdef, face)
      rot, bb = wrap_frame(cdef, face)
      shift = Geom::Transformation.translation([-bb.center.x, -bb.min.y, -bb.center.z])
      ents.add_instance(cdef, shift * rot)
    end

    def self.build_custom(ents, t)
      rgb = t[:color].is_a?(Array) ? t[:color] : hex_rgb(t[:color])
      w = t[:w].to_f
      hz = t[:hz].to_f
      depth = [t[:depth].to_f, 5].max
      cdef = t[:comp].to_s.empty? ? nil : Sketchup.active_model.definitions[t[:comp]]
      if cdef && cdef.valid? && t[:shape] == 'component'
        wrap_component(ents, cdef, t[:face])
        return
      end
      if t[:shape] == 'round'
        part_cyl(ents, 0, 0, w, 0, depth, rgb)
        face_label(ents, t[:prefix], depth + 0.5, w * 0.6)
      else
        part(ents, -w, w, 0, depth, -hz, hz, rgb)
        face_label(ents, t[:prefix], depth + 0.5, [hz * 0.7, w * 0.5].min)
      end
    end

    # Размер компонента пользователя (полуширина/полувысота в мм) для превью и выхода кабеля
    def self.component_size(cname, face)
      cdef = Sketchup.active_model.definitions[cname]
      return nil unless cdef && cdef.valid?
      _rot, bb = wrap_frame(cdef, face)
      # BoundingBox: width — X, depth — Z
      [(bb.width.to_mm / 2.0).round(1), (bb.depth.to_mm / 2.0).round(1)]
    end

    def self.custom_dialog
      m = Sketchup.active_model
      comps = m.definitions.reject { |d| d.image? || d.group? || d.name.start_with?('ЭЛ') }.map(&:name).sort
      data = {
        types: custom_lib.map { |k, v| v.merge(key: k, color: v[:color].is_a?(Array) ? format('#%02x%02x%02x', *v[:color]) : v[:color]) },
        cables: [''] + CABLES.map(&:first),
        comps: comps, faces: FACES
      }
      @cdlg.close if @cdlg && @cdlg.visible?
      @cdlg = UI::HtmlDialog.new(dialog_title: 'Свои устройства', preferences_key: 'ak_elektrika_custom',
                                 scrollable: true, resizable: true, width: 460, height: 720,
                                 min_width: 380, min_height: 480, style: UI::HtmlDialog::STYLE_DIALOG)
      dlg = @cdlg
      json = JSON.generate(data)
      dlg.set_html(CUSTOM_HTML.sub('__DATA__') { json })
      dlg.add_action_callback('save') do |_c, js|
        UI.start_timer(0, false) { custom_save(JSON.parse(js.to_s)) && custom_dialog }
      end
      dlg.add_action_callback('remove') do |_c, key|
        UI.start_timer(0, false) do
          if UI.messagebox('Удалить устройство из библиотеки? Поставленные в модели останутся.', MB_YESNO) == IDYES
            lib = user_lib
            lib.delete(key.to_s)
            save_user_lib(lib)
            custom_dialog
          end
        end
      end
      dlg.add_action_callback('place') do |_c, key|
        UI.start_timer(0, false) do
          Sketchup.active_model.select_tool(PlaceTool.new(key.to_s))
        end
      end
      dlg.show
    end

    def self.custom_save(h)
      t = sym_hash(h)
      name = t[:name].to_s.strip
      prefix = t[:prefix].to_s.strip
      if name.empty? || prefix.empty?
        UI.messagebox('Нужны название и префикс номера.')
        return false
      end
      if TYPES.values.any? { |x| x[:name] == name }
        UI.messagebox('Такое название уже есть среди встроенных механизмов.')
        return false
      end
      key = t[:key].to_s.empty? ? "c#{Time.now.to_i}#{rand(1000)}" : t[:key].to_s
      lib = user_lib
      rec = {
        name: name, prefix: prefix, h: t[:h].to_f, w: t[:w].to_f, hz: t[:hz].to_f, depth: t[:depth].to_f,
        color: hex_rgb(t[:color]), shape: t[:shape].to_s, comp: t[:comp].to_s, face: t[:face].to_s,
        ceil: !!t[:ceil], block: !!t[:block], cable: t[:cable].to_s,
        rev: (lib[key] ? lib[key][:rev].to_i + 1 : 0)
      }
      if rec[:shape] == 'component'
        size = component_size(rec[:comp], rec[:face])
        unless size
          UI.messagebox('Выберите компонент модели для вида устройства.')
          return false
        end
        rec[:w], rec[:hz] = size
      end
      lib[key] = rec
      save_user_lib(lib)
      # уже стоящие в модели — обновить описание и вид
      if devices.any? { |d| d.get_attribute(DICT, 'type') == key }
        m = Sketchup.active_model
        m.start_operation('Электрика: обновить своё устройство', true)
        save_model_type(key, rec)
        definition(key)
        m.commit_operation
      end
      true
    rescue StandardError => e
      log_error('custom_save', e)
      UI.messagebox("Ошибка сохранения: #{e.message}")
      false
    end

    CUSTOM_HTML = <<~HTML.freeze
      <!doctype html><html><head><meta charset="utf-8">
      <style>
        body{font:14px "Segoe UI",Arial,sans-serif;margin:12px;background:#f3f4f6;color:#222}
        h3{margin:4px 0 8px;font-size:15px}
        .t{display:flex;align-items:center;gap:8px;padding:7px 8px;margin:4px 0;background:#fff;border:1px solid #d6d9de;border-radius:6px}
        .sw{width:18px;height:18px;border-radius:3px;flex:none;border:1px solid #888}
        .t .n{flex:1}
        .t small{color:#666}
        button{font-size:13px;padding:5px 9px;border-radius:4px;border:1px solid #999;background:#fff;cursor:pointer}
        .pri{background:#1a73e8;color:#fff;border-color:#1a73e8}
        form{background:#fff;border:1px solid #d6d9de;border-radius:6px;padding:10px;margin-top:10px}
        label{display:block;margin-top:7px;font-size:12px;color:#555}
        input,select{width:100%;font-size:14px;padding:5px;box-sizing:border-box;border:1px solid #bbb;border-radius:4px}
        .row{display:flex;gap:8px}.row>div{flex:1}
        .chk{display:flex;gap:16px;margin-top:9px}.chk label{display:flex;align-items:center;gap:5px;margin:0;font-size:13px;color:#222}
        .chk input{width:auto}
        .hint{font-size:12px;color:#666;margin-top:6px}
        .empty{color:#777;font-style:italic;padding:6px}
      </style></head><body>
      <h3>Библиотека</h3><div id="list"></div>
      <form id="f" onsubmit="return false">
        <h3 id="ft">Новое устройство</h3>
        <input type="hidden" id="key">
        <div class="row"><div><label>Название</label><input id="name" placeholder="Терморегулятор"></div>
          <div style="flex:.45"><label>Префикс номера</label><input id="prefix" placeholder="ТР"></div></div>
        <div class="row"><div><label>Высота центра от пола, мм</label><input id="h" type="number" value="900"></div>
          <div><label>Цвет</label><input id="color" type="color" value="#8a8a8a"></div></div>
        <label>Вид</label>
        <select id="shape"><option value="box">Прямоугольник</option><option value="round">Круг</option>
          <option value="component">Компонент из модели</option></select>
        <div id="dims"><div class="row"><div><label>Ширина, мм</label><input id="w" type="number" value="70"></div>
          <div><label>Высота, мм</label><input id="hz" type="number" value="70"></div>
          <div><label>Глубина, мм</label><input id="depth" type="number" value="15"></div></div></div>
        <div id="compbox" style="display:none"><label>Компонент</label><select id="comp"></select>
          <label>Ориентация компонента</label><select id="face"></select>
          <div class="hint">Задняя сторона ляжет на стену, центр — в точку установки. Ориентация — куда «смотрит» лицевая сторона в самом компоненте.</div></div>
        <label>Кабель по умолчанию</label><select id="cable"></select>
        <div class="chk"><label><input type="checkbox" id="ceil">можно на потолок</label>
          <label><input type="checkbox" id="block">встаёт в блок (рамка 71)</label></div>
        <div style="margin-top:12px;display:flex;gap:8px"><button class="pri" id="save">Сохранить</button>
          <button id="clear">Новое</button></div>
      </form>
      <script>
        var D=__DATA__, $=function(i){return document.getElementById(i)};
        function opt(sel,vals,labels){sel.innerHTML='';vals.forEach(function(v,i){var o=document.createElement('option');
          o.value=v;o.textContent=labels?labels[i]:(v||'— как в последний раз —');sel.appendChild(o);});}
        opt($('cable'),D.cables); opt($('comp'),D.comps.length?D.comps:[''],D.comps.length?null:['(в модели нет компонентов)']);
        opt($('face'),Object.keys(D.faces),Object.values(D.faces));
        function shape(){var c=$('shape').value==='component';$('compbox').style.display=c?'':'none';
          $('dims').style.display=c?'none':'';$('hz').disabled=$('shape').value==='round';}
        $('shape').onchange=shape;
        function fill(t){$('key').value=t.key||'';$('name').value=t.name||'';$('prefix').value=t.prefix||'';
          $('h').value=t.h||900;$('color').value=t.color||'#8a8a8a';$('shape').value=t.shape||'box';
          $('w').value=t.w?t.w*2:70;$('hz').value=t.hz?t.hz*2:70;$('depth').value=t.depth||15;
          $('comp').value=t.comp||$('comp').value;$('face').value=t.face||'+Y';$('cable').value=t.cable||'';
          $('ceil').checked=!!t.ceil;$('block').checked=!!t.block;$('ft').textContent=t.key?'Правка: '+t.name:'Новое устройство';shape();}
        function render(){var L=$('list');L.innerHTML='';
          if(!D.types.length){L.innerHTML='<div class="empty">Пока пусто — заполните форму ниже.</div>';return;}
          D.types.forEach(function(t){var d=document.createElement('div');d.className='t';
            d.innerHTML='<span class="sw"></span><span class="n"></span><button class="pri">Поставить</button><button>Правка</button><button>✕</button>';
            d.querySelector('.sw').style.background=t.color;
            d.querySelector('.n').innerHTML='';var b=document.createElement('b');b.textContent=t.name;
            var s=document.createElement('small');s.textContent='  '+t.prefix+' · h='+t.h+(t.cable?' · '+t.cable:'');
            d.querySelector('.n').appendChild(b);d.querySelector('.n').appendChild(s);
            var bs=d.querySelectorAll('button');
            bs[0].onclick=function(){sketchup.place(t.key)};bs[1].onclick=function(){fill(t)};
            bs[2].onclick=function(){sketchup.remove(t.key)};L.appendChild(d);});}
        render();fill({});
        $('clear').onclick=function(){fill({})};
        $('save').onclick=function(){var r={key:$('key').value,name:$('name').value,prefix:$('prefix').value,
          h:+$('h').value,color:$('color').value,shape:$('shape').value,w:(+$('w').value)/2,
          hz:($('shape').value==='round'?+$('w').value:+$('hz').value)/2,depth:+$('depth').value,
          comp:$('comp').value,face:$('face').value,cable:$('cable').value,ceil:$('ceil').checked,block:$('block').checked};
          sketchup.save(JSON.stringify(r));};
      </script></body></html>
    HTML

    def self.mount_axes(n)
      n = n.normalize
      x = n.parallel?(Z_AXIS) ? X_AXIS.clone : n * Z_AXIS
      x.normalize!
      [x, n, x * n]
    end

    def self.mount_transform(pt, n)
      x, y, z = mount_axes(n)
      Geom::Transformation.axes(pt, x, y, z)
    end

    # ================= поиск =================

    def self.devices(model = Sketchup.active_model)
      model.entities.grep(Sketchup::ComponentInstance).select do |i|
        i.valid? && i.get_attribute(DICT, 'type')
      end
    end

    def self.device?(e)
      e.is_a?(Sketchup::ComponentInstance) && e.valid? && e.get_attribute(DICT, 'type')
    end

    def self.device_by_id(id)
      return nil unless id
      devices.find { |i| i.get_attribute(DICT, 'id') == id }
    end

    def self.routes(model = Sketchup.active_model)
      model.entities.grep(Sketchup::Group).select { |g| g.valid? && g.get_attribute(DICT, 'cable') }
    end

    def self.route?(e)
      e.is_a?(Sketchup::Group) && e.valid? && e.get_attribute(DICT, 'cable')
    end

    def self.routes_of(ids)
      routes.select { |g| ids.include?(g.get_attribute(DICT, 'from')) || ids.include?(g.get_attribute(DICT, 'to')) }
    end

    # Трассы из выделения: выделенные трассы + трассы выделенных механизмов
    def self.routes_from_selection
      sel = Sketchup.active_model.selection
      rs = sel.select { |e| route?(e) }
      ids = sel.select { |e| device?(e) }.map { |d| d.get_attribute(DICT, 'id') }
      (rs + routes_of(ids)).uniq
    end

    # ================= точки трассы =================

    def self.get_pts(g)
      a = g.get_attribute(DICT, 'pts')
      return [] unless a.is_a?(Array)
      a.each_slice(3).map { |x, y, z| Geom::Point3d.new(x.to_f.mm, y.to_f.mm, z.to_f.mm) }
    end

    def self.pts_sig(pts)
      pts.map { |p| [p.x.to_mm.round, p.y.to_mm.round, p.z.to_mm.round].join(',') }.join(';')
    end

    def self.set_pts(g, pts)
      g.set_attribute(DICT, 'pts', pts.flat_map { |p| [p.x.to_mm, p.y.to_mm, p.z.to_mm] })
    end

    def self.dev_tangent(inst)
      hnorm(inst.transformation.xaxis)
    end

    def self.ceiling_mount?(inst)
      inst.transformation.yaxis.normalize.z.abs > 0.7
    end

    # Выход кабеля из механизма (p0) и точка под потолком (p1)
    # level — уровень трассы (0 — под самым потолком), slot_mm — смещение вдоль механизма
    def self.dev_points(inst, level, slot_mm)
      t = inst.transformation
      type = inst.get_attribute(DICT, 'type')
      o = t.origin
      lvl = level.to_i
      step = sf('lane_step').mm
      zc = (sf('floor_z') + sf('ceiling_h') - sf('offset')).mm - lvl * step
      sv = vec(dev_tangent(inst), slot_mm.to_f.mm)
      if ceiling_mount?(inst)
        p0 = o + sv
      else
        nh = hnorm(t.yaxis)
        top = tinfo(type)[:top].mm
        p0 = Geom::Point3d.new(o.x, o.y, o.z + top)
        p0 += vec(nh, sf('offset').mm + lvl * step)
        p0 += sv
      end
      [p0, Geom::Point3d.new(p0.x, p0.y, zc)]
    end

    def self.route_ends(g)
      [g.get_attribute(DICT, 'level').to_i, g.get_attribute(DICT, 'slot_a').to_f, g.get_attribute(DICT, 'slot_b').to_f]
    end

    def self.auto_points(g, a, b)
      lvl, sa, sb = route_ends(g)
      pa = dev_points(a, lvl, sa)
      pb = dev_points(b, lvl, sb)
      ta = pa.last
      tb = pb.last
      mid = []
      if setting('ceil_mode') == 'ortho'
        mid << (g.get_attribute(DICT, 'order') == 'y' ? Geom::Point3d.new(ta.x, tb.y, ta.z) : Geom::Point3d.new(tb.x, ta.y, ta.z))
      end
      RM.clean(pa + mid + pb.reverse)
    end

    # Цепочка рёбер группы → упорядоченные точки (nil, если не простая ломаная)
    def self.chain_points(g)
      t = g.transformation
      edges = g.entities.grep(Sketchup::Edge)
      return nil if edges.empty?
      verts = edges.flat_map(&:vertices).uniq
      return nil if verts.any? { |v| v.edges.size > 2 }
      ends = verts.select { |v| v.edges.size == 1 }
      return nil unless ends.size == 2
      pts = []
      v = ends[0]
      prev = nil
      (edges.size + 1).times do
        pts << v.position.transform(t)
        e = v.edges.find { |x| x != prev }
        break unless e
        prev = e
        v = e.other_vertex(v)
      end
      pts
    end

    # Рёбра правили штатными инструментами?
    def self.geometry_changed?(g)
      return false if g.get_attribute(DICT, 'pts').nil?
      chain = chain_points(g)
      return false unless chain && chain.size >= 2
      stored = g.get_attribute(DICT, 'sig')
      pts_sig(chain) != stored && pts_sig(chain.reverse) != stored
    end

    # Ручную правку штатными инструментами — забрать в точки трассы
    def self.sync_from_geometry(g)
      return unless geometry_changed?(g)
      chain = chain_points(g)
      a = device_by_id(g.get_attribute(DICT, 'from'))
      if a
        lvl, sa, = route_ends(g)
        p0 = dev_points(a, lvl, sa)[0]
        chain.reverse! if chain.last.distance(p0) < chain.first.distance(p0)
      end
      set_pts(g, chain)
      g.set_attribute(DICT, 'sig', pts_sig(chain))
      g.set_attribute(DICT, 'manual', true)
    end

    def self.draw_route(g, pts)
      g.transformation = Geom::Transformation.new
      g.entities.clear!
      return false if pts.size < 2
      edges = g.entities.add_edges(pts)
      mat = cable_material(g.get_attribute(DICT, 'cable'))
      (edges || []).each { |e| e.material = mat }
      set_pts(g, pts)
      g.set_attribute(DICT, 'sig', pts_sig(pts))
      true
    end

    def self.route_name(g)
      "#{g.get_attribute(DICT, 'from')}–#{g.get_attribute(DICT, 'to')} " \
        "#{g.get_attribute(DICT, 'group')} #{g.get_attribute(DICT, 'cable')}"
    end

    # Раскладка уровней и мест подхода для всех трасс модели
    def self.relayout(rs)
      items = []
      rs.each do |g|
        a = device_by_id(g.get_attribute(DICT, 'from'))
        b = device_by_id(g.get_attribute(DICT, 'to'))
        next unless a && b
        fixed = g.get_attribute(DICT, 'manual')
        items << { key: g.entityID, a: a.entityID, b: b.entityID,
                   pa: a.transformation.origin, pb: b.transformation.origin,
                   ta: dev_tangent(a), tb: dev_tangent(b),
                   level: fixed ? g.get_attribute(DICT, 'level').to_i : nil }
      end
      res = RM.layout(items, sf('lane_step'))
      rs.each do |g|
        r = res[g.entityID]
        next unless r && r[:level]
        g.set_attribute(DICT, 'level', r[:level])
        g.set_attribute(DICT, 'slot_a', r[:slot_a].to_f)
        g.set_attribute(DICT, 'slot_b', r[:slot_b].to_f)
      end
    end

    # Перерисовать трассу по текущей раскладке: авто — заново, ручную — переподключить концы
    def self.redraw(g)
      a = device_by_id(g.get_attribute(DICT, 'from'))
      b = device_by_id(g.get_attribute(DICT, 'to'))
      return false unless a && b
      g.name = route_name(g)
      old = get_pts(g)
      if g.get_attribute(DICT, 'manual') && old.size >= 2
        lvl, sa, sb = route_ends(g)
        a0, a1 = dev_points(a, lvl, sa)
        b0, b1 = dev_points(b, lvl, sb)
        draw_route(g, RM.reattach_both(old, a0, a1, b0, b1))
      else
        g.set_attribute(DICT, 'manual', false)
        draw_route(g, auto_points(g, a, b))
      end
    end

    # Главный пересчёт: раскладка всех трасс + перерисовка. Вызывать внутри операции.
    def self.update_all
      rs = routes
      rs.each { |g| sync_from_geometry(g) }
      relayout(rs)
      missing = []
      rs.each do |g|
        next if editing?(g)
        missing << route_name(g) unless redraw(g)
      end
      missing
    end

    def self.editing?(g)
      path = Sketchup.active_model.active_path
      path && path.include?(g)
    end

    # ================= операции =================

    def self.place(type, origin, n, h_mm, neighbor = nil)
      m = Sketchup.active_model
      m.start_operation("Электрика: #{tinfo(type)[:name]}", true)
      # своё устройство — копию описания в модель (для другого компьютера и спецификации)
      save_model_type(type, user_lib[type]) if !TYPES.key?(type) && user_lib[type]
      inst = m.entities.add_instance(definition(type), mount_transform(origin, n))
      attach_device(inst)
      id = next_id(type)
      inst.name = id
      inst.layer = tag(TAG_DEV)
      inst.set_attribute(DICT, 'type', type)
      inst.set_attribute(DICT, 'id', id)
      inst.set_attribute(DICT, 'h_mm', h_mm.to_f) if h_mm
      if neighbor && neighbor.valid?
        bid = neighbor.get_attribute(DICT, 'block') || next_block_id
        neighbor.set_attribute(DICT, 'block', bid)
        inst.set_attribute(DICT, 'block', bid)
      end
      m.commit_operation
      Sketchup.status_text = "Поставлен #{id}"
      inst
    rescue StandardError => e
      m.abort_operation if m
      log_error('place', e)
      UI.messagebox("Ошибка установки: #{e.message}")
      nil
    end

    def self.create_route(a, b, cable, group)
      return unless a.valid? && b.valid?
      m = Sketchup.active_model
      m.start_operation('Электрика: кабель', true)
      g = m.entities.add_group
      g.layer = tag(TAG_ROUTE)
      g.set_attribute(DICT, 'from',  a.get_attribute(DICT, 'id'))
      g.set_attribute(DICT, 'to',    b.get_attribute(DICT, 'id'))
      g.set_attribute(DICT, 'cable', cable)
      g.set_attribute(DICT, 'group', group)
      g.set_attribute(DICT, 'order', 'x')
      g.set_attribute(DICT, 'manual', false)
      # временная точка, чтобы группа не исчезла пустой до раскладки
      g.entities.add_cpoint(a.transformation.origin)
      update_all
      if g.valid? && get_pts(g).size >= 2
        m.commit_operation
      else
        m.abort_operation
        UI.messagebox('Трассу построить не удалось (механизмы совпадают по положению?).')
      end
    rescue StandardError => e
      m.abort_operation if m
      log_error('create_route', e)
      UI.messagebox("Ошибка построения трассы: #{e.message}")
    end

    def self.reset_routes
      rs = routes_from_selection
      rs = routes if rs.empty?
      if rs.empty?
        UI.messagebox('Трасс в модели нет.')
        return
      end
      is_manual = ->(g) { g.get_attribute(DICT, 'manual') || geometry_changed?(g) }
      manual = rs.count { |g| is_manual.call(g) }
      if manual > 0
        r = UI.messagebox("Ручная правка есть у #{manual} из #{rs.size} трасс.\n" \
                          "Да — сбросить и их в авто.\nНет — ручные не трогать.", MB_YESNOCANCEL)
        return if r == IDCANCEL
        rs = rs.reject { |g| is_manual.call(g) } if r == IDNO
      end
      m = Sketchup.active_model
      m.start_operation('Электрика: перестроить трассы', true)
      rs.each do |g|
        g.set_attribute(DICT, 'manual', false)
        g.set_attribute(DICT, 'sig', pts_sig(chain_points(g) || get_pts(g)))
      end
      missing = update_all
      m.commit_operation
      UI.messagebox("Не найдены механизмы для трасс:\n#{missing.join("\n")}") if missing.any?
    rescue StandardError => e
      m.abort_operation if m
      log_error('reset_routes', e)
      UI.messagebox("Ошибка перестроения: #{e.message}")
    end

    def self.flip_selected
      rs = Sketchup.active_model.selection.select { |e| route?(e) }
      if rs.empty?
        UI.messagebox('Выделите трассу — угол на потолке переложится на другую сторону.')
        return
      end
      m = Sketchup.active_model
      m.start_operation('Электрика: переложить угол', true)
      rs.each do |g|
        g.set_attribute(DICT, 'order', g.get_attribute(DICT, 'order') == 'y' ? 'x' : 'y')
        g.set_attribute(DICT, 'manual', false)
        g.set_attribute(DICT, 'sig', pts_sig(chain_points(g) || get_pts(g)))
      end
      update_all
      m.commit_operation
    rescue StandardError => e
      m.abort_operation if m
      log_error('flip', e)
    end

    def self.relane_all
      m = Sketchup.active_model
      m.start_operation('Электрика: развести трассы', true)
      update_all
      m.commit_operation
    rescue StandardError => e
      m.abort_operation if m
      log_error('relane', e)
    end

    # ================= наблюдатели =================

    class DeviceObserver < Sketchup::EntityObserver
      def onChangeEntity(entity)
        Elektrika.queue_device(entity)
      rescue StandardError => e
        Elektrika.log_error('observer', e)
      end
    end

    class EntsObserver < Sketchup::EntitiesObserver
      def onElementAdded(_ents, entity)
        Elektrika.queue_added(entity) if entity.is_a?(Sketchup::ComponentInstance)
      rescue StandardError => e
        Elektrika.log_error('ents observer', e)
      end
    end

    class ModelObs < Sketchup::ModelObserver
      def onTransactionUndo(_m)
        Elektrika.mark_undo
      end

      def onTransactionRedo(_m)
        Elektrika.mark_undo
      end
    end

    class AppObs < Sketchup::AppObserver
      def onNewModel(m)
        Elektrika.attach_model(m)
      end

      def onOpenModel(m)
        Elektrika.attach_model(m)
      end
    end

    DEV_OBS   = DeviceObserver.new
    ENTS_OBS  = EntsObserver.new
    MODEL_OBS = ModelObs.new
    APP_OBS   = AppObs.new

    def self.tsig(inst)
      inst.transformation.to_a.map { |v| v.round(4) }
    end

    def self.attach_device(inst)
      inst.remove_observer(DEV_OBS)
      inst.add_observer(DEV_OBS)
      @tcache[inst.entityID] = tsig(inst)
    end

    def self.attach_model(m)
      m.entities.remove_observer(ENTS_OBS)
      m.entities.add_observer(ENTS_OBS)
      m.remove_observer(MODEL_OBS)
      m.add_observer(MODEL_OBS)
      devices(m).each { |d| attach_device(d) }
    rescue StandardError => e
      log_error('attach_model', e)
    end

    # Изменения механизмов во время отмены/повтора не трогаем (трассы откатываются вместе с ними)
    def self.mark_undo
      @undoing = true
      UI.start_timer(0.3, false) { @undoing = false }
    end

    def self.queue_device(inst)
      return if @busy || !inst.valid?
      key = inst.entityID
      sig = tsig(inst)
      return if @tcache[key] == sig
      @tcache[key] = sig
      @queue[key] = inst
      @timer ||= UI.start_timer(0.05, false) { flush_queue }
    end

    def self.flush_queue
      @timer = nil
      insts = @queue.values.select(&:valid?)
      @queue = {}
      return if @undoing
      ids = insts.map { |i| i.get_attribute(DICT, 'id') }.compact
      return if ids.empty?
      return if routes_of(ids).empty?
      m = Sketchup.active_model
      @busy = true
      m.start_operation('Электрика: трассы за механизмом', true, false, true)
      update_all
      m.commit_operation
    rescue StandardError => e
      m.abort_operation if m
      log_error('flush_queue', e)
    ensure
      @busy = false
    end

    def self.queue_added(inst)
      return if @busy
      @added << inst
      @atimer ||= UI.start_timer(0.05, false) { flush_added }
    end

    # Копия механизма (Ctrl+Перемещение) получает свой номер
    def self.flush_added
      @atimer = nil
      list = @added.select { |e| device?(e) }
      @added = []
      return if list.empty?
      if @undoing
        list.each { |d| attach_device(d) }
        return
      end
      m = Sketchup.active_model
      all = devices
      dup = list.select do |d|
        id = d.get_attribute(DICT, 'id')
        all.count { |x| x.get_attribute(DICT, 'id') == id } > 1
      end
      list.each { |d| attach_device(d) }
      return if dup.empty?
      @busy = true
      m.start_operation('Электрика: номер копии', true, false, true)
      dup.each do |d|
        id = next_id(d.get_attribute(DICT, 'type'))
        d.set_attribute(DICT, 'id', id)
        d.delete_attribute(DICT, 'block')
        d.name = id
      end
      m.commit_operation
    rescue StandardError => e
      m.abort_operation if m
      log_error('flush_added', e)
    ensure
      @busy = false
    end

    # ================= блоки механизмов =================

    def self.occupied?(pos, devs)
      devs.any? { |x| x.transformation.origin.distance(pos) < 20.mm }
    end

    # Ближайший механизм того же ряда в радиусе прилипания → позиция рядом с шагом pitch
    def self.snap_position(c, nh, type)
      return nil unless blockable?(type)
      pitch = sf('pitch').mm
      radius = sf('snap').mm
      devs = devices.select { |d| blockable?(d.get_attribute(DICT, 'type')) }
      best = nil
      bd = nil
      devs.each do |d|
        t = d.transformation
        next unless t.yaxis.normalize.dot(nh) > 0.99
        o = t.origin
        next if (c - o).dot(nh).abs > 30.mm
        tx = hnorm(t.xaxis)
        dt = (c - o).dot(tx)
        dz = c.z - o.z
        dist = Math.hypot(dt, dz)
        next if dist > radius
        if bd.nil? || dist < bd
          best = [d, tx, dt, dz]
          bd = dist
        end
      end
      return nil unless best
      d, tx, dt, dz = best
      dir = if dt.abs >= dz.abs
              dt >= 0 ? tx : tx.reverse
            else
              dz >= 0 ? Z_AXIS.clone : Z_AXIS.reverse
            end
      pos = d.transformation.origin
      8.times do
        pos += vec(dir, pitch)
        break unless occupied?(pos, devs)
      end
      return nil if occupied?(pos, devs)
      { origin: pos, neighbor: d, h: pos.z.to_mm - sf('floor_z') }
    end

    # ================= спецификация =================

    def self.report
      rs = routes
      devs = devices
      if rs.empty? && devs.empty?
        UI.messagebox('В модели нет ни механизмов, ни трасс.')
        return
      end
      m = Sketchup.active_model
      changed = rs.select { |g| geometry_changed?(g) }
      if changed.any?
        m.start_operation('Электрика: сверка трасс', true)
        changed.each { |g| sync_from_geometry(g) }
        m.commit_operation
      end

      zap_end = sf('zap_end')
      zap_panel = sf('zap_panel')
      rows = []
      totals = Hash.new(0.0)
      rs.each do |g|
        from = g.get_attribute(DICT, 'from')
        to = g.get_attribute(DICT, 'to')
        ends = [device_by_id(from), device_by_id(to)]
        zap = ends.map { |d| d && d.get_attribute(DICT, 'type') == 'panel' ? zap_panel : zap_end }.sum / 1000.0
        len = RM.length(get_pts(g)).to_mm / 1000.0
        cable = g.get_attribute(DICT, 'cable')
        totals[cable] += len + zap
        note = []
        note << 'правка вручную' if g.get_attribute(DICT, 'manual')
        note << 'нет механизма' if ends.include?(nil)
        rows << [g.get_attribute(DICT, 'group').to_s, cable, from, to, len, len + zap, note.join(', ')]
      end
      rows.sort_by! { |r| [r[0], r[2].to_s, r[3].to_s] }

      dev_count = Hash.new(0)
      devs.each { |d| dev_count[tinfo(d.get_attribute(DICT, 'type'))[:name]] += 1 }
      frames = Hash.new(0)
      blocks = Hash.new(0)
      devs.each do |d|
        next unless blockable?(d.get_attribute(DICT, 'type'))
        b = d.get_attribute(DICT, 'block')
        b ? blocks[b] += 1 : frames[1] += 1
      end
      blocks.each_value { |n| frames[n] += 1 }

      summary = +"КАБЕЛЬ (с запасом):\n"
      totals.sort.each { |c, l| summary << "  #{c}: #{num_s(l)} м (к закупке #{l.ceil} м)\n" }
      summary << "\nМЕХАНИЗМЫ:\n"
      dev_count.sort.each { |n, c| summary << "  #{n}: #{c} шт.\n" }
      summary << "\nРАМКИ:\n"
      frames.sort.each { |n, c| summary << "  #{n}-местная: #{c} шт.\n" }
      summary << "\nТрасс: #{rs.size}. Сохранить спецификацию в CSV?"
      return unless UI.messagebox(summary, MB_YESNO) == IDYES

      dir = m.path.to_s.empty? ? nil : File.dirname(m.path)
      path = UI.savepanel('Спецификация', dir, 'elektrika_spec.csv')
      return unless path
      path += '.csv' unless path.downcase.end_with?('.csv')
      File.open(path, 'w:UTF-8') do |f|
        f.write("﻿")
        f.puts 'Группа;Кабель;От;До;Длина трассы, м;С запасом, м;Примечание'
        rows.each { |r| f.puts [r[0], r[1], r[2], r[3], num_s(r[4]), num_s(r[5]), r[6]].join(';') }
        f.puts
        f.puts 'ИТОГО ПО КАБЕЛЮ;;;;;м;к закупке, м'
        totals.sort.each { |c, l| f.puts "#{c};;;;;#{num_s(l)};#{l.ceil}" }
        f.puts
        f.puts 'МЕХАНИЗМЫ;шт.'
        dev_count.sort.each { |n, c| f.puts "#{n};#{c}" }
        f.puts
        f.puts 'РАМКИ;шт.'
        frames.sort.each { |n, c| f.puts "#{n}-местная;#{c}" }
      end
      UI.messagebox("Сохранено:\n#{path}")
    rescue StandardError => e
      log_error('report', e)
      UI.messagebox("Ошибка спецификации: #{e.message}")
    end

    # ================= диалоги =================

    def self.cable_dialog(a, b)
      groups = routes.map { |g| g.get_attribute(DICT, 'group').to_s }.reject(&:empty?).uniq.sort
      # кабель по типу механизма (RJ-45 — UTP, 3ф розетка — 5×2,5), иначе последний выбранный
      typed = [a, b].map { |d| tinfo(d.get_attribute(DICT, 'type'))[:cable].to_s }.find { |c| !c.empty? }
      data = {
        title: "#{a.name} → #{b.name}",
        cables: CABLES.map { |c| { name: c[0], color: format('#%02x%02x%02x', *c[1]) } },
        last: typed || @last_cable, group: @last_group, groups: groups
      }
      json = JSON.generate(data)
      html = CABLE_HTML.sub('__DATA__') { json }
      @dlg.close if @dlg && @dlg.visible?
      @dlg = UI::HtmlDialog.new(dialog_title: "Кабель #{a.name} → #{b.name}",
                                preferences_key: 'ak_elektrika_cable2',
                                scrollable: true, resizable: true,
                                width: 380, height: 600, min_width: 320, min_height: 420,
                                style: UI::HtmlDialog::STYLE_DIALOG)
      dlg = @dlg
      dlg.set_html(html)
      dlg.add_action_callback('ok') do |_ctx, cable, group|
        UI.start_timer(0, false) do
          dlg.close
          @last_cable = cable.to_s unless typed
          @last_group = group.to_s
          create_route(a, b, cable.to_s, group.to_s) unless cable.to_s.strip.empty?
        end
      end
      dlg.add_action_callback('cancel') { |_ctx| UI.start_timer(0, false) { dlg.close } }
      dlg.show
    end

    CABLE_HTML = <<~HTML.freeze
      <!doctype html><html><head><meta charset="utf-8">
      <style>
        body{font:14px "Segoe UI",Arial,sans-serif;margin:12px;background:#f3f4f6;color:#222}
        h3{margin:0 0 10px;font-size:16px}
        .c{display:flex;align-items:center;gap:10px;padding:9px 10px;margin:5px 0;background:#fff;
           border:2px solid #d6d9de;border-radius:6px;cursor:pointer;font-size:15px;user-select:none}
        .c:hover{border-color:#9db7e8}
        .c.sel{border-color:#1a73e8;background:#e8f0fe;font-weight:600}
        .sw{width:28px;height:8px;border-radius:2px;flex:none}
        label{display:block;margin-top:12px;font-size:13px;color:#555}
        input{width:100%;font-size:15px;padding:7px;box-sizing:border-box;border:1px solid #bbb;border-radius:4px}
        .btns{margin-top:14px;display:flex;gap:8px}
        button{flex:1;font-size:15px;padding:9px;border-radius:5px;border:1px solid #999;background:#fff;cursor:pointer}
        #ok{background:#1a73e8;color:#fff;border-color:#1a73e8}
      </style></head><body>
      <h3 id="t"></h3>
      <div id="list"></div>
      <label>Другой кабель (если нет в списке)</label><input id="custom" placeholder="например ВВГнг-LS 3×16">
      <label>Группа</label><input id="grp" list="gl"><datalist id="gl"></datalist>
      <div class="btns"><button id="ok">Проложить</button><button id="cancel">Отмена</button></div>
      <script>
        var D = __DATA__; var cur = D.last;
        document.getElementById('t').textContent = D.title;
        var list = document.getElementById('list');
        function render(){ list.innerHTML='';
          D.cables.forEach(function(c){ var d=document.createElement('div');
            d.className='c'+(c.name===cur?' sel':'');
            d.innerHTML='<span class="sw" style="background:'+c.color+'"></span><span></span>';
            d.lastChild.textContent=c.name;
            d.onclick=function(){cur=c.name;document.getElementById('custom').value='';render();};
            d.ondblclick=function(){cur=c.name;ok();};
            list.appendChild(d); }); }
        render();
        if(!D.cables.some(function(c){return c.name===cur;})) document.getElementById('custom').value=cur||'';
        var g=document.getElementById('grp'); g.value=D.group;
        var gl=document.getElementById('gl');
        D.groups.forEach(function(x){var o=document.createElement('option');o.value=x;gl.appendChild(o);});
        function ok(){ var cu=document.getElementById('custom').value.trim();
          sketchup.ok(cu||cur, g.value.trim()); }
        document.getElementById('ok').onclick=ok;
        document.getElementById('cancel').onclick=function(){sketchup.cancel();};
        document.addEventListener('keydown',function(e){
          if(e.key==='Enter')ok(); if(e.key==='Escape')sketchup.cancel();});
      </script></body></html>
    HTML

    def self.settings_dialog
      modes = { 'ortho' => 'по осям модели (Г-образно)', 'direct' => 'кратчайшая' }
      keys = %w[floor_z ceiling_h offset lane_step pitch snap zap_end zap_panel grid]
      prompts = ['Отметка чистого пола, мм', 'Высота до потолка, мм', 'Отступ трассы от стены/потолка, мм',
                 'Разнос соседних трасс, мм', 'Шаг механизмов в блоке, мм', 'Радиус прилипания, мм',
                 'Запас у механизма, мм', 'Запас у щита, мм', 'Шаг сдвига сегмента, мм', 'Трасса по потолку']
      defaults = keys.map { |k| sf(k) } + [modes[setting('ceil_mode')] || modes['ortho']]
      lists = keys.map { '' } + [modes.values.join('|')]
      res = UI.inputbox(prompts, defaults, lists, 'Электрика — настройки')
      return unless res
      m = Sketchup.active_model
      m.start_operation('Электрика: настройки', true)
      keys.each_with_index { |k, i| set_setting(k, res[i].to_f) }
      set_setting('ceil_mode', modes.key(res[keys.size]) || 'ortho')
      m.commit_operation
      if routes.any? && UI.messagebox('Применить к трассам? Авто-трассы перестроятся, у ручных переподключатся концы.', MB_YESNO) == IDYES
        m.start_operation('Электрика: применить настройки', true)
        update_all
        m.commit_operation
      end
    rescue StandardError => e
      log_error('settings', e)
    end

    def self.toggle_edge_colors
      ro = Sketchup.active_model.rendering_options
      ro['EdgeColorMode'] = ro['EdgeColorMode'] == 0 ? 1 : 0
      Sketchup.status_text = ro['EdgeColorMode'] == 0 ? 'Рёбра по материалу — трассы цветом кабеля' : 'Рёбра одним цветом'
    end

    # ================= инструмент: механизм =================

    class PlaceTool
      @@heights = {}

      def initialize(type)
        @type = type
        @ip = Sketchup::InputPoint.new
        @cand = nil
      end

      def h_mm
        @@heights[@type] || Elektrika.tinfo(@type)[:h]
      end

      def activate
        update_status
      end

      def resume(_view)
        update_status
      end

      def update_status
        t = Elektrika.tinfo(@type)
        extra = t[:ceil] ? '; клик по потолку — потолочный' : ''
        extra += '; рядом с механизмом — встаёт в блок' if Elektrika.blockable?(@type)
        Sketchup.status_text = "#{t[:name]}: клик по стене — центр на #{h_mm} мм от пола#{extra}. " \
                               'Высоту можно набрать с клавиатуры.'
        Sketchup.vcb_label = 'Высота, мм'
        Sketchup.vcb_value = h_mm.to_s
      end

      def enableVCB?
        true
      end

      def onUserText(text, view)
        v = text.to_s.tr(',', '.').to_f
        if v <= 0
          UI.beep
          return
        end
        @@heights[@type] = v.round
        update_status
        view.invalidate
      end

      def compute(view, x, y)
        @ip.pick(view, x, y)
        @cand = nil
        return unless @ip.valid?
        face = @ip.face
        return unless face
        n = face.normal.transform(@ip.transformation)
        return if n.length < 1e-9
        n.normalize!
        pt = @ip.position
        n.reverse! if n.dot(view.camera.eye - pt) < 0
        if n.z.abs < 0.3
          nh = Elektrika.hnorm(n)
          c = Geom::Point3d.new(pt.x, pt.y, (Elektrika.sf('floor_z') + h_mm).mm)
          s = Elektrika.snap_position(c, nh, @type)
          @cand = if s
                    { origin: s[:origin], n: nh, h: s[:h], neighbor: s[:neighbor] }
                  else
                    { origin: c, n: nh, h: h_mm }
                  end
        elsif Elektrika.tinfo(@type)[:ceil] && n.z < -0.95
          @cand = { origin: pt, n: Geom::Vector3d.new(0, 0, -1), h: nil }
        end
      rescue StandardError => e
        Elektrika.log_error('compute', e)
        @cand = nil
      end

      def onMouseMove(_flags, x, y, view)
        compute(view, x, y)
        view.tooltip = @cand && @cand[:neighbor] ? "в блок с #{@cand[:neighbor].name}" : ''
        view.invalidate
      end

      def draw(view)
        @ip.draw(view) if @ip.valid? && @ip.display?
        return unless @cand
        x, y, = Elektrika.mount_axes(@cand[:n])
        up = @cand[:h] ? Z_AXIS : y.cross(x).normalize
        x = x.normalize
        o = @cand[:origin] + Elektrika.vec(@cand[:n], 2.mm)
        rw = Elektrika.tinfo(@type)[:w].mm
        rh = (@cand[:h] ? Elektrika.tinfo(@type)[:hz] : Elektrika.tinfo(@type)[:w]).mm
        pts = [[-1, -1], [1, -1], [1, 1], [-1, 1]].map do |a, b|
          o + Elektrika.vec(x, a * rw) + Elektrika.vec(up, b * rh)
        end
        view.line_stipple = ''
        view.line_width = 3
        view.drawing_color = @cand[:neighbor] ? 'lime' : 'dodgerblue'
        view.draw(GL_LINE_LOOP, pts)
      end

      def onLButtonDown(_flags, x, y, view)
        compute(view, x, y)
        unless @cand
          UI.beep
          Sketchup.status_text = Elektrika.tinfo(@type)[:ceil] ? 'Нужна грань стены или потолка.' : 'Этот механизм ставится только на стену.'
          return
        end
        Elektrika.place(@type, @cand[:origin], @cand[:n], @cand[:h], @cand[:neighbor])
        view.invalidate
      end
    end

    # ================= инструмент: кабель =================

    class CableTool
      def initialize
        @ip = Sketchup::InputPoint.new
        @a = nil
        @mouse = nil
      end

      def activate
        reset
      end

      def resume(_view)
        status
      end

      def reset
        @a = nil
        Sketchup.active_model.selection.clear
        status
      end

      def status
        Sketchup.status_text = @a ? "Кабель от #{@a.name}: выберите механизм «куда». Esc — сброс." : 'Кабель: выберите механизм «откуда».'
      end

      def pick_device(view, x, y)
        ph = view.pick_helper
        ph.do_pick(x, y)
        ph.count.times do |i|
          path = ph.path_at(i)
          next unless path
          path.each { |e| return e if Elektrika.device?(e) }
        end
        nil
      end

      def onMouseMove(_flags, x, y, view)
        @ip.pick(view, x, y)
        @mouse = @ip.position
        dev = pick_device(view, x, y)
        view.tooltip = dev ? dev.name : ''
        view.invalidate if @a
      end

      def draw(view)
        return unless @a && @a.valid? && @mouse
        view.drawing_color = 'red'
        view.line_stipple = '-'
        view.line_width = 2
        view.draw_line(@a.transformation.origin, @mouse)
      end

      def onLButtonDown(_flags, x, y, view)
        dev = pick_device(view, x, y)
        unless dev
          UI.beep
          return
        end
        if @a.nil?
          @a = dev
          Sketchup.active_model.selection.add(dev)
          status
        elsif dev == @a
          UI.beep
        else
          a = @a
          reset
          Elektrika.cable_dialog(a, dev)
        end
        view.invalidate
      end

      def onCancel(_reason, view)
        reset
        view.invalidate
      end

      def deactivate(view)
        view.invalidate
      end
    end

    # ================= инструмент: правка трассы =================
    # Нажать на сегмент и тянуть (или клик — увести — клик). Сегмент двигается
    # по одной из осей, перпендикулярных ему; ось выбирается по первому движению
    # мыши или фиксируется стрелками (→ красная X, ← зелёная Y, ↑ синяя Z, ↓ авто).
    # Соседи достраиваются под прямым углом, концы остаются на механизмах.

    class EditTool
      AXIS_KEYS = { VK_RIGHT => :x, VK_LEFT => :y, VK_UP => :z }.freeze
      AXIS_COLORS = { x: 'red', y: 'green', z: 'blue', h: 'gray' }.freeze
      PICK_PX = 6

      def initialize
        @lock = nil
        reset_state
      end

      def reset_state
        @hover = nil  # [group, p, q]
        @drag = nil
        @preview = nil
      end

      def activate
        status
      end

      def resume(_view)
        status
      end

      def status
        lock = @lock ? " Ось зафиксирована: #{@lock.to_s.upcase}." : ''
        Sketchup.status_text = 'Правка трассы: нажмите на сегмент и тяните — ось по движению мыши. ' \
                               "Стрелки: → X, ← Y, ↑ Z (вверх/вниз), ↓ авто.#{lock} Esc — отмена."
        Sketchup.vcb_label = 'Сдвиг, мм'
      end

      def deactivate(view)
        abort_drag
        view.invalidate
      end

      def enableVCB?
        !@drag.nil?
      end

      def pick_segment(view, x, y)
        ph = view.pick_helper
        ph.do_pick(x, y)
        ph.count.times do |i|
          path = ph.path_at(i)
          next unless path
          g = path.find { |e| Elektrika.route?(e) }
          e = path.last
          next unless g && e.is_a?(Sketchup::Edge)
          t = g.transformation
          return [g, e.start.position.transform(t), e.end.position.transform(t)]
        end
        nil
      end

      def global_axis(sym)
        { x: X_AXIS, y: Y_AXIS, z: Z_AXIS }[sym].clone
      end

      # Оси, по которым можно сдвинуть сегмент направления s
      def candidates(s)
        list = {}
        %i[x y z].each { |k| list[k] = global_axis(k) if global_axis(k).dot(s).abs < 0.01 }
        if s.z.abs < 0.01 && !list.key?(:x) && !list.key?(:y)
          h = Z_AXIS.cross(s)
          list[:h] = h.normalize if h.length > 1e-9 # косой сегмент на потолке
        end
        list
      end

      # Плоскость, содержащая ось и обращённая к камере
      def drag_plane(view, origin, axis)
        d = view.camera.direction
        n = d - Elektrika.vec(axis, d.dot(axis))
        if n.length < 1e-6
          n = axis.parallel?(Z_AXIS) ? X_AXIS.clone : Z_AXIS.cross(axis)
        end
        [origin, n.normalize]
      end

      def set_axis(view, key)
        d = @drag
        d[:key] = key
        d[:axis] = d[:cands][key]
        d[:plane] = drag_plane(view, d[:mid], d[:axis])
        d[:start] = Geom.intersect_line_plane(view.pickray(d[:sx], d[:sy]), d[:plane]) || d[:mid]
      end

      # Ось по направлению движения мыши на экране
      def auto_axis(view, x, y)
        d = @drag
        mv = Geom::Vector3d.new(x - d[:sx], y - d[:sy], 0)
        return nil if mv.length < PICK_PX
        mv.normalize!
        s0 = view.screen_coords(d[:mid])
        size = view.pixels_to_model(50, d[:mid])
        best = nil
        bv = -1
        d[:cands].each do |k, a|
          s1 = view.screen_coords(d[:mid] + Elektrika.vec(a, size))
          sv = Geom::Vector3d.new(s1.x - s0.x, s1.y - s0.y, 0)
          next if sv.length < 1e-6
          v = sv.normalize.dot(mv).abs
          if v > bv
            bv = v
            best = k
          end
        end
        best
      end

      def onMouseMove(_flags, x, y, view)
        if @drag
          @drag[:mx] = x
          @drag[:my] = y
          unless @drag[:axis]
            k = auto_axis(view, x, y)
            if k
              set_axis(view, k)
              @drag[:moved] = true
            end
          end
          update_drag(view, x, y) if @drag[:axis]
        else
          @hover = pick_segment(view, x, y)
        end
        view.invalidate
      end

      def update_drag(view, x, y)
        pp = Geom.intersect_line_plane(view.pickray(x, y), @drag[:plane])
        return unless pp
        @drag[:moved] = true if (pp - @drag[:start]).length > 0.5.mm
        dist = (pp - @drag[:start]).dot(@drag[:axis])
        grid = Elektrika.sf('grid').mm
        dist = (dist / grid).round * grid if grid > 0
        apply_preview(dist)
      end

      def apply_preview(dist)
        @drag[:dist] = dist
        d = Elektrika.vec(@drag[:axis], dist)
        @preview = dist.abs < 1e-6 ? @drag[:pts] : RouteMath.move_segment(@drag[:pts], @drag[:idx], d)
        Sketchup.vcb_value = dist.to_mm.round.to_s
      end

      def onKeyDown(key, _repeat, _flags, view)
        if key == VK_DOWN
          @lock = nil
          if @drag
            @drag[:axis] = nil
            @drag[:dist] = 0.0
            @preview = @drag[:pts]
          end
          status
          view.invalidate
          return true
        end
        k = AXIS_KEYS[key]
        return false unless k
        if @drag && !@drag[:cands].key?(k)
          UI.beep
          Sketchup.status_text = "Ось #{k.to_s.upcase} идёт вдоль сегмента — по ней сдвиг невозможен."
          return true
        end
        @lock = (@lock == k ? nil : k)
        if @drag
          if @lock
            set_axis(view, @lock)
            update_drag(view, @drag[:mx], @drag[:my]) if @drag[:mx]
          else
            @drag[:axis] = nil
          end
        end
        status
        view.invalidate
        true
      end

      def onLButtonDown(_flags, x, y, view)
        if @drag
          commit
          view.invalidate
          return
        end
        hit = pick_segment(view, x, y)
        return UI.beep unless hit
        g = hit[0]
        m = Sketchup.active_model
        m.start_operation('Электрика: правка трассы', true)
        Elektrika.sync_from_geometry(g)
        pts = Elektrika.get_pts(g)
        idx = segment_index(pts, hit[1], hit[2])
        unless idx
          m.abort_operation
          UI.beep
          return
        end
        p = pts[idx]
        q = pts[idx + 1]
        cands = candidates((q - p).normalize)
        if cands.empty?
          m.abort_operation
          UI.beep
          return
        end
        @drag = { g: g, pts: pts, idx: idx, cands: cands, dist: 0.0, moved: false,
                  mid: Geom::Point3d.linear_combination(0.5, p, 0.5, q), sx: x, sy: y }
        @preview = pts
        if @lock && cands.key?(@lock)
          set_axis(view, @lock)
        elsif cands.size == 1
          set_axis(view, cands.keys.first)
        end
        view.invalidate
      end

      def onLButtonUp(_flags, _x, _y, view)
        return unless @drag && @drag[:moved]
        commit
        view.invalidate
      end

      def onUserText(text, view)
        return unless @drag && @drag[:axis]
        v = text.to_s.tr(',', '.').to_f
        sign = @drag[:dist] < 0 ? -1 : 1
        v = v.abs * sign unless text.to_s.strip.start_with?('-')
        apply_preview(v.mm)
        commit
        view.invalidate
      end

      def onCancel(_reason, view)
        abort_drag
        view.invalidate
      end

      def commit
        d = @drag
        reset_state
        if d.nil? || d[:axis].nil? || d[:dist].abs < 1e-6
          Sketchup.active_model.abort_operation
          return
        end
        pts = RouteMath.move_segment(d[:pts], d[:idx], Elektrika.vec(d[:axis], d[:dist]))
        d[:g].set_attribute(DICT, 'manual', true)
        Elektrika.draw_route(d[:g], pts)
        Sketchup.active_model.commit_operation
      rescue StandardError => e
        Sketchup.active_model.abort_operation
        Elektrika.log_error('edit commit', e)
      end

      def abort_drag
        Sketchup.active_model.abort_operation if @drag
        reset_state
      end

      def segment_index(pts, p, q)
        tol = 1.mm
        (0...(pts.size - 1)).each do |i|
          a = pts[i]
          b = pts[i + 1]
          return i if (a.distance(p) < tol && b.distance(q) < tol) || (a.distance(q) < tol && b.distance(p) < tol)
        end
        nil
      end

      def draw(view)
        view.line_stipple = ''
        if @drag
          if @drag[:axis]
            len = view.pixels_to_model(400, @drag[:mid])
            a = Elektrika.vec(@drag[:axis], len)
            view.line_width = 1
            view.line_stipple = '_'
            view.drawing_color = AXIS_COLORS[@drag[:key]]
            view.draw_line(@drag[:mid] - a, @drag[:mid] + a)
            view.line_stipple = ''
          end
          if @preview && @preview.size >= 2
            view.line_width = 4
            view.drawing_color = 'magenta'
            view.draw(GL_LINE_STRIP, @preview)
          end
        elsif @hover
          view.line_width = 5
          view.drawing_color = 'magenta'
          view.draw_line(@hover[1], @hover[2])
        end
      end
    end

    # ================= меню и панель =================

    def self.cmd(name, icon, tip, &block)
      c = UI::Command.new(name) do
        begin
          block.call
        rescue StandardError => e
          log_error(name, e)
          UI.messagebox("#{name}: #{e.message}")
        end
      end
      path = File.join(ICON_DIR, "#{icon}.svg")
      if File.exist?(path)
        c.small_icon = path
        c.large_icon = path
      end
      c.tooltip = name
      c.status_bar_text = tip
      c
    end

    unless file_loaded?(__FILE__)
      sel = ->(tool) { Sketchup.active_model.select_tool(tool) }
      place_cmds = TYPES.keys.map do |type|
        cmd(TYPES[type][:name], type, "Поставить: #{TYPES[type][:name].downcase}") { sel.call(PlaceTool.new(type)) }
      end
      c_custom = cmd('Свои устройства', 'custom', 'Библиотека своих устройств: создать, править, поставить') { custom_dialog }
      c_cable  = cmd('Кабель от–до', 'cable', 'Выбрать два механизма и проложить трассу') { sel.call(CableTool.new) }
      c_edit   = cmd('Правка трассы', 'edit', 'Потянуть сегмент трассы — соседи достроятся под прямым углом') { sel.call(EditTool.new) }
      c_flip   = cmd('Переложить угол', 'flip', 'Перенести угол Г-образной трассы на потолке (сбрасывает правку)') { flip_selected }
      c_reset  = cmd('Перестроить (сброс в авто)', 'rebuild', 'Выделенные трассы / трассы выделенных механизмов; без выделения — все') { reset_routes }
      c_lane   = cmd('Развести трассы', 'lanes', 'Пересчитать раскладку: длинные выше, без перехлёстов') { relane_all }
      c_report = cmd('Спецификация', 'report', 'Кабель по группам, механизмы, рамки, CSV') { report }
      c_colors = cmd('Цвет трасс вкл/выкл', 'colors', 'Рёбра по материалу — трассы цветом кабеля') { toggle_edge_colors }
      c_set    = cmd('Настройки', 'settings', 'Пол, потолок, разнос, блоки, запасы') { settings_dialog }

      menu = UI.menu('Extensions').add_submenu('Электрика')
      GROUPS.each do |gk, gname|
        sub = menu.add_submenu(gname)
        TYPES.keys.each_with_index { |type, i| sub.add_item(place_cmds[i]) if TYPES[type][:group] == gk }
      end
      menu.add_item(c_custom)
      menu.add_separator
      [c_cable, c_edit, c_flip, c_reset, c_lane].each { |c| menu.add_item(c) }
      menu.add_separator
      [c_report, c_colors, c_set].each { |c| menu.add_item(c) }

      tbd = UI::Toolbar.new('Электрика — механизмы')
      prev = nil
      TYPES.keys.each_with_index do |type, i|
        tbd.add_separator if prev && prev != TYPES[type][:group]
        prev = TYPES[type][:group]
        tbd.add_item(place_cmds[i])
      end
      tbd.add_separator
      tbd.add_item(c_custom)

      tb = UI::Toolbar.new('Электрика')
      [c_cable, c_edit, c_flip, c_reset, c_lane].each { |c| tb.add_item(c) }
      tb.add_separator
      [c_report, c_colors, c_set].each { |c| tb.add_item(c) }
      # Новая версия — панель показываем принудительно; дальше SketchUp помнит её состояние сам
      fresh = Sketchup.read_default('ak_elektrika', 'tb_version') != VERSION
      [tbd, tb].each do |bar|
        if fresh || bar.get_last_state == TB_NEVER_SHOWN
          bar.show
        else
          bar.restore
        end
        UI.start_timer(1.0, false) { bar.show unless bar.visible? } if bar.get_last_state != TB_HIDDEN
      end
      Sketchup.write_default('ak_elektrika', 'tb_version', VERSION)

      Sketchup.add_observer(APP_OBS)
      attach_model(Sketchup.active_model)
      file_loaded(__FILE__)
    end

  end
end
