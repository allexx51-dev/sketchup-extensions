# frozen_string_literal: true

# Крепёж и спецификация по системам RUDNIK. Нормы расхода скатной, Balast Південь и наземной
# Landing — по документации поставщика. Balast Схід-Захід и Block — по устройству системы,
# нормы расхода поставщиком не подтверждены.
# Геометрия деталей в модели условная (бруски), количество — по правилам.

module K2A
  module SolarPlanner
    GROUND_ROW_GAP_MM = 22.0      # шов между верхней и нижней панелью стола
    EW_RIDGE_GAP_MM = 20.0        # шов по коньку «домика» восток–запад
    GROUND_TILT_DEG = 30.0
    GROUND_LOW_EDGE_MM = 695.0    # отметка нижнего края панелей стола
    GROUND_PURLIN_EXTRA_MM = 166.0 # прогон длиннее поля панелей

    SYSTEM_LABELS = {
      'rail_clamp' => 'SolarSet (скатная, профиль)',
      'ballast' => 'Balast Південь',
      'ballast_ew' => 'Balast Схід-Захід',
      'ground' => 'Landing (наземная)',
      'block' => 'Block (беспрофильная, профнастил)'
    }.freeze

    # Битумная лента под саморез: отрезок 50 мм (лента шириной 50 мм) на каждую точку
    SCREW_TAPE_M = 0.05

    # Массы деталей, кг (по данным поставщика). Чего нет в данных — в массу не входит.
    # Масса конструкции: крепёж и балластные блоки, без панелей.
    RAIL_KG_PER_M = { 'al_ld' => 0.75, 'g41' => 1.7097 }.freeze
    SPLICE_KG = { 'al_ld' => 0.1, 'g41' => 0.45 }.freeze
    PART_KG = {
      clamp: 0.082, clamp_bal: 0.073, anchor_tbit: 0.186, triangle_south: 3.54,
      row_connector: 0.98, spoiler: 2.14
    }.freeze
    # Прижимы оцинкованные под G41 — масса по данным поставщика; у алюминиевого профиля — общая 0,082
    CLAMP_KG = { 'g41' => { z: 0.080, p: 0.089 } }.freeze
    # Кронштейны: масса по данным поставщика; у остальных креплений неизвестна — в массу не входят
    ANCHOR_KG = { 'l45' => 0.21, 'tbit' => 0.186 }.freeze

    # Масса прижимов линии профиля: два Z на концах и n_mid П между панелями
    def self.clamps_kg(profile, n_mid)
      kg = CLAMP_KG[profile]
      kg ? 2 * kg[:z] + n_mid * kg[:p] : (n_mid + 2) * PART_KG[:clamp]
    end

    # Линии профиля под панелью — доли размера панели поперёк профиля.
    # Две — обычная схема; три — дополнительная линия посередине (снег, ветер, длинные панели).
    def self.rail_ratios(cfg)
      cfg['railLines'].to_i == 3 ? [0.22, 0.5, 0.78] : [0.22, 0.78]
    end

    # Кронштейн L45: нержавеющий под алюминиевый профиль, оцинкованный под G41 (прайс RUDNIK)
    def self.anchor_subs(anchor, profile)
      anchor == 'l45' ? { 'mat' => profile == 'g41' ? 'оц' : 'нерж' } : {}
    end

    def self.add_line(bom, key, qty, unit, subs = {})
      return if qty.nil? || qty.to_f <= 0.0

      bom[:lines] << { 'key' => key, 'subs' => subs, 'qty' => qty, 'unit' => unit }
    end

    def self.merge_lines(lines)
      merged = {}
      lines.each do |l|
        id = [l['key'], l['subs'].to_a.sort]
        if merged[id]
          merged[id]['qty'] += l['qty']
        else
          merged[id] = l.dup
        end
      end
      merged.values
    end

    def self.box(ents, geom, name, layer, mat, u0, u1, v0, v1, z0, z1)
      return if u1 - u0 < 0.5 || v1 - v0 < 0.5 || z1 - z0 < 0.5

      grp = ents.add_group
      grp.name = name
      grp.layer = layer
      create_rail_geometry(grp.entities, geom[:origin], geom[:u], geom[:v], geom[:n], u0, u1, v0, v1, z0, z1, mat)
    end

    # Брус между двумя точками, заданными в координатах ската [u, v, z] в мм.
    # Нужен для наклонных деталей: сторона треугольника, кроква.
    def self.beam(ents, geom, name, layer, mat, p1, p2, width, height)
      a = point_on_basis(geom[:origin], geom[:u], geom[:v], geom[:n], p1[0], p1[1], p1[2])
      b = point_on_basis(geom[:origin], geom[:u], geom[:v], geom[:n], p2[0], p2[1], p2[2])
      axis = b - a
      len = axis.length
      return if len < 0.04 # короче 1 мм

      grp = ents.add_group
      grp.name = name
      grp.layer = layer
      grp.material = mat
      w = width.mm * 0.5
      h = height.mm * 0.5
      face = grp.entities.add_face([-w, -h, 0], [w, -h, 0], [w, h, 0], [-w, h, 0])
      face.reverse! if face.normal.z < 0
      face.pushpull(len)
      grp.transformation = Geom::Transformation.new(a, axis)
    end

    def self.place_def(ents, geom, defn, layer, u, v, z, tr_extra = nil)
      pt = point_on_basis(geom[:origin], geom[:u], geom[:v], geom[:n], u, v, z)
      tr = Geom::Transformation.axes(pt, geom[:u], geom[:v], geom[:n])
      tr *= tr_extra if tr_extra
      inst = ents.add_instance(defn, tr)
      inst.layer = layer
      inst
    end

    # Крепёж и спецификация строятся заново по панелям, которые фактически стоят в группе.
    # Операцию отмены открывает вызывающий код.
    def self.rebuild_array(model, group)
      cfg = array_cfg(group)
      return false unless cfg

      geom = array_geom(cfg)
      ents = group.entities
      junk = ents.to_a - panel_instances(group)
      ents.erase_entities(junk) unless junk.empty?

      cells = array_cells(group, cfg, geom)
      rows = LayoutMath.cells_to_rows(cells)
      bom = { lines: [], kg: 0.0 }
      if cfg['includeMounting']
        case cfg['mount']
        when 'ballast' then build_ballast_south(model, ents, cfg, geom, rows, bom)
        when 'ballast_ew' then build_ballast_ew(model, ents, cfg, geom, rows, bom)
        when 'ground' then build_ground(model, ents, cfg, geom, rows, bom)
        when 'block' then build_block(model, ents, cfg, geom, rows, bom)
        else build_rail(model, ents, cfg, geom, rows, bom)
        end
      end

      panels = cells.length * [cfg['cellPanels'].to_i, 1].max
      bom_data = {
        'panelModel' => cfg['panelModel'],
        'panelSize' => cfg['panelSize'],
        'orientation' => cfg['orientation'],
        'mountType' => cfg['includeMounting'] ? (SYSTEM_LABELS[cfg['mount']] || cfg['mount'].to_s) : 'без крепежа',
        'panelsCount' => panels,
        'rowGapMm' => cfg['rowGapMm'].to_f.round,
        'localTiltDeg' => cfg['localTiltDeg'].to_f.round(1),
        'powerKw' => (panels * cfg['powerW'].to_f / 1000.0).round(2),
        'lines' => merge_lines(bom[:lines]),
        'structureKg' => bom[:kg].round(1)
      }
      group.set_attribute(ATTR_DICT, 'bom_json', JSON.generate(bom_data))
      group.name = "#{cfg['namePrefix']}_#{panels}шт"
      true
    end

    # ---------- SolarSet: скатная кровля, два профиля на ряд ----------
    # Профиль поперёк ряда (вдоль ската): два профиля под каждой стопкой панелей, прижимы на
    # сторонах панелей, параллельных ряду.
    # Высота профиля берётся по нижнему краю панели — схема рассчитана на панели без наклона к кровле.
    def self.build_rail_across(model, ents, cfg, geom, rows, bom)
      profile = RAIL_KG_PER_M.key?(cfg['profile']) ? cfg['profile'] : 'al_ld'
      anchor = cfg['anchor'].to_s.empty? ? 'l45' : cfg['anchor'].to_s
      thick = cfg['thickMm'].to_f
      t_sub = { 't' => thick.round }
      panel_u = cfg['panelUMm'].to_f
      base_z = geom[:base_z]
      step = [cfg['bracketStepMm'].to_f, 300.0].max

      tag_rails    = model.layers.add('PV_Профиль')
      tag_clamps   = model.layers.add('PV_Прижимы')
      tag_brackets = model.layers.add('PV_Кронштейны')
      mid_def = get_or_create_clamp_def(model, "PV_Прижим_П_#{thick.round}", thick, true)
      end_def = get_or_create_clamp_def(model, "PV_Прижим_Z_#{thick.round}", thick, false)
      bracket_def = get_or_create_bracket_def(model, 'PV_Кронштейн_Опора')
      mat = get_or_create_material(model, 'PV_Aluminum_Rail', [195, 203, 212])
      rail_h = 40.0
      rail_w = 40.0

      LayoutMath.cells_to_stacks(rows.flatten, cfg['rowGapMm'].to_f + 30.0).each do |stack|
        span = stack.last[:v1] - stack.first[:v0]
        plan = LayoutMath.piece_plan(span + 2.0 * cfg['railOverhangMm'].to_f)
        total = plan.sum
        centre = (stack.first[:v0] + stack.last[:v1]) * 0.5
        v_start = centre - total * 0.5
        v_end = centre + total * 0.5

        rail_ratios(cfg).each do |ratio|
          plan.each { |len| add_line(bom, "railPiece.#{profile}", 1, 'шт', 'len' => len.round) }
          add_line(bom, "splice.#{profile}", plan.length - 1, 'шт')
          bom[:kg] += total / 1000.0 * RAIL_KG_PER_M[profile] + (plan.length - 1) * SPLICE_KG[profile]

          line_u = stack.first[:u0] + ratio * panel_u
          pos = v_start
          plan.each_with_index do |len, i|
            box(ents, geom, 'PV_Профиль', tag_rails, mat, line_u - rail_w * 0.5, line_u + rail_w * 0.5,
                pos + 1.0, pos + len - 1.0, base_z - rail_h, base_z)
            pos += len
            next if i == plan.length - 1

            box(ents, geom, 'PV_Соединитель', tag_rails, mat, line_u - rail_w * 0.5 - 4.0, line_u + rail_w * 0.5 + 4.0,
                pos - 100.0, pos + 100.0, base_z - rail_h - 4.0, base_z - rail_h + 12.0)
          end

          [stack.first[:v0] - 12.0, stack.last[:v1] + 12.0].each { |cv| place_def(ents, geom, end_def, tag_clamps, line_u, cv, base_z) }
          add_line(bom, "clampZ.#{profile}", 2, 'шт', t_sub)
          (0...(stack.length - 1)).each do |i|
            place_def(ents, geom, mid_def, tag_clamps, line_u, (stack[i][:v1] + stack[i + 1][:v0]) * 0.5, base_z)
          end
          add_line(bom, "clampP.#{profile}", stack.length - 1, 'шт', t_sub)
          bom[:kg] += clamps_kg(profile, stack.length - 1)

          anchors = bracket_positions(v_start + 120.0, v_end - 120.0, step)
          unless anchor == 'screw'
            scale = Geom::Transformation.scaling(1.0, 1.0, [(base_z - rail_h) / 100.0, 0.2].max)
            anchors.each { |av| place_def(ents, geom, bracket_def, tag_brackets, line_u, av, 0.0, scale) }
          end
          add_line(bom, "anchor.#{anchor}", anchors.length, 'шт', anchor_subs(anchor, profile))
          add_line(bom, 'tape', anchors.length * SCREW_TAPE_M, 'м') if anchor == 'screw'
          bom[:kg] += anchors.length * ANCHOR_KG[anchor] if ANCHOR_KG[anchor]
        end
      end
    end

    def self.build_rail(model, ents, cfg, geom, rows, bom)
      return build_rail_across(model, ents, cfg, geom, rows, bom) if cfg['railDir'] == 'across'

      profile = RAIL_KG_PER_M.key?(cfg['profile']) ? cfg['profile'] : 'al_ld'
      anchor = cfg['anchor'].to_s.empty? ? 'l45' : cfg['anchor'].to_s
      thick = cfg['thickMm'].to_f
      t_sub = { 't' => thick.round }
      tilt_rad = geom[:tilt_rad]
      proj_v = geom[:proj_v]
      row_h = geom[:row_h]
      base_z = geom[:base_z]
      step = [cfg['bracketStepMm'].to_f, 300.0].max

      tag_rails    = model.layers.add('PV_Профиль')
      tag_clamps   = model.layers.add('PV_Прижимы')
      tag_brackets = model.layers.add('PV_Кронштейны')
      mid_def = get_or_create_clamp_def(model, "PV_Прижим_П_#{thick.round}", thick, true)
      end_def = get_or_create_clamp_def(model, "PV_Прижим_Z_#{thick.round}", thick, false)
      bracket_def = get_or_create_bracket_def(model, 'PV_Кронштейн_Опора')
      mat = get_or_create_material(model, 'PV_Aluminum_Rail', [195, 203, 212])
      tr_tilt = Geom::Transformation.rotation(ORIGIN, X_AXIS, tilt_rad)
      rail_h = 40.0
      rail_w = 40.0

      rows.each do |row|
        LayoutMath.split_series(row, cfg['gapUMm'].to_f).each do |seg|
          span = seg.last[:u1] - seg.first[:u0]
          plan = LayoutMath.piece_plan(span + 2.0 * cfg['railOverhangMm'].to_f)
          total = plan.sum
          centre = (seg.first[:u0] + seg.last[:u1]) * 0.5
          u_start = centre - total * 0.5
          u_end = centre + total * 0.5
          v0 = seg.first[:v0]

          rail_ratios(cfg).each do |ratio|
            plan.each { |len| add_line(bom, "railPiece.#{profile}", 1, 'шт', 'len' => len.round) }
            add_line(bom, "splice.#{profile}", plan.length - 1, 'шт')
            bom[:kg] += total / 1000.0 * RAIL_KG_PER_M[profile] + (plan.length - 1) * SPLICE_KG[profile]

            line_v = v0 + ratio * proj_v
            rise = tilt_rad >= 0.0 ? ratio : 1.0 - ratio
            z_top = base_z + rise * row_h
            z_bot = z_top - rail_h
            pos = u_start
            plan.each_with_index do |len, i|
              box(ents, geom, 'PV_Профиль', tag_rails, mat, pos + 1.0, pos + len - 1.0,
                  line_v - rail_w * 0.5, line_v + rail_w * 0.5, z_bot, z_top)
              pos += len
              next if i == plan.length - 1

              box(ents, geom, 'PV_Соединитель', tag_rails, mat, pos - 100.0, pos + 100.0,
                  line_v - rail_w * 0.5 - 4.0, line_v + rail_w * 0.5 + 4.0, z_bot - 4.0, z_bot + 12.0)
            end

            [seg.first[:u0] - 12.0, seg.last[:u1] + 12.0].each do |cu|
              place_def(ents, geom, end_def, tag_clamps, cu, line_v, z_top, tr_tilt)
            end
            add_line(bom, "clampZ.#{profile}", 2, 'шт', t_sub)

            (0...(seg.length - 1)).each do |i|
              place_def(ents, geom, mid_def, tag_clamps, (seg[i][:u1] + seg[i + 1][:u0]) * 0.5, line_v, z_top, tr_tilt)
            end
            add_line(bom, "clampP.#{profile}", seg.length - 1, 'шт', t_sub)
            bom[:kg] += clamps_kg(profile, seg.length - 1)

            anchors = bracket_positions(u_start + 120.0, u_end - 120.0, step)
            unless anchor == 'screw' # саморезы в профнастил — кронштейна нет
              anchors.each do |bu|
                scale = Geom::Transformation.scaling(1.0, 1.0, [z_bot / 100.0, 0.2].max)
                place_def(ents, geom, bracket_def, tag_brackets, bu, line_v, 0.0, scale)
              end
            end
            add_line(bom, "anchor.#{anchor}", anchors.length, 'шт', anchor_subs(anchor, profile))
            add_line(bom, 'tape', anchors.length * SCREW_TAPE_M, 'м') if anchor == 'screw'
            bom[:kg] += anchors.length * ANCHOR_KG[anchor] if ANCHOR_KG[anchor]
          end
        end
      end
    end

    # ---------- Block: беспрофильная система для профнастила ----------
    # Короткий блок L 310 под каждой точкой прижима: две линии на ряд, блоки на концах ряда
    # и на стыках панелей. Нормы приняты по устройству системы, поставщиком не подтверждены:
    # заклёпок 4 на блок, ленты 310 мм под блок. Панель лежит на блоках без наклона.
    BLOCK_LEN_MM = 310.0
    BLOCK_H_MM = 50.0
    BLOCK_RIVETS = 4

    def self.build_block(model, ents, cfg, geom, rows, bom)
      thick = cfg['thickMm'].to_f
      t_sub = { 't' => thick.round }
      tilt_rad = geom[:tilt_rad]
      proj_v = geom[:proj_v]
      row_h = geom[:row_h]
      base_z = geom[:base_z]

      tag_rails  = model.layers.add('PV_Профиль')
      tag_clamps = model.layers.add('PV_Прижимы')
      mid_def = get_or_create_clamp_def(model, "PV_Прижим_П_#{thick.round}", thick, true)
      end_def = get_or_create_clamp_def(model, "PV_Прижим_Z_#{thick.round}", thick, false)
      mat = get_or_create_material(model, 'PV_Aluminum_Rail', [195, 203, 212])
      tr_tilt = Geom::Transformation.rotation(ORIGIN, X_AXIS, tilt_rad)
      half = BLOCK_LEN_MM * 0.5

      rows.each do |row|
        LayoutMath.split_series(row, cfg['gapUMm'].to_f).each do |seg|
          v0 = seg.first[:v0]
          joints = (0...(seg.length - 1)).map { |i| (seg[i][:u1] + seg[i + 1][:u0]) * 0.5 }
          ends = [seg.first[:u0], seg.last[:u1]]
          [0.22, 0.78].each do |ratio|
            line_v = v0 + ratio * proj_v
            z_top = base_z + (tilt_rad >= 0.0 ? ratio : 1.0 - ratio) * row_h
            (ends + joints).each do |u|
              box(ents, geom, 'PV_Блок', tag_rails, mat, u - half, u + half, line_v - 25.0, line_v + 25.0, z_top - BLOCK_H_MM, z_top)
            end
            place_def(ents, geom, end_def, tag_clamps, ends[0] - 12.0, line_v, z_top, tr_tilt)
            place_def(ents, geom, end_def, tag_clamps, ends[1] + 12.0, line_v, z_top, tr_tilt)
            joints.each { |u| place_def(ents, geom, mid_def, tag_clamps, u, line_v, z_top, tr_tilt) }

            blocks = ends.length + joints.length
            add_line(bom, 'block', blocks, 'шт')
            add_line(bom, 'clampZ.block', 2, 'шт', t_sub)
            add_line(bom, 'clampP.block', joints.length, 'шт', t_sub)
            add_line(bom, 'rivet', blocks * BLOCK_RIVETS, 'шт')
            add_line(bom, 'tape', blocks * BLOCK_LEN_MM / 1000.0, 'м')
          end
        end
      end
    end

    # ---------- Balast Південь: три треугольника на панель альбомом ----------
    def self.build_ballast_south(model, ents, cfg, geom, rows, bom)
      tilt_rad = geom[:tilt_rad]
      proj_v = geom[:proj_v]
      row_h = geom[:row_h]
      base_z = geom[:base_z]
      thick = cfg['thickMm'].to_f
      t_sub = { 't' => thick.round }
      angle = cfg['localTiltDeg'].to_f.abs.round
      block_h = cfg['ballastHMm'].to_f
      block_ratios = cfg['ballastPerJoint'].to_i >= 3 ? [0.15, 0.5, 0.85] : [0.15, 0.85]
      bar = 30.0
      top_z = base_z + row_h

      tag_frame   = model.layers.add('PV_Профиль')
      tag_clamps  = model.layers.add('PV_Прижимы')
      tag_ballast = model.layers.add('PV_Балласт')
      ballast_def = get_or_create_ballast_def(model, cfg['ballastLMm'].to_f, cfg['ballastWMm'].to_f, block_h)
      z_def = get_or_create_clamp_def(model, "PV_Прижим_Z_#{thick.round}", thick, false)
      w_def = get_or_create_clamp_def(model, "PV_Прижим_W_#{thick.round}", thick, true)
      mat = get_or_create_material(model, 'PV_Aluminum_Rail', [195, 203, 212])
      tr_tilt = Geom::Transformation.rotation(ORIGIN, X_AXIS, tilt_rad)

      row_info = []
      rows.each do |row|
        v0 = row.first[:v0]
        v1 = v0 + proj_v
        link_us = []
        spans = []
        LayoutMath.split_series(row, cfg['gapUMm'].to_f).each do |seg|
          spans << [seg.first[:u0], seg.last[:u1]]
          LayoutMath.ballast_lines(seg).each do |u, kind|
            box(ents, geom, 'PV_Треугольник', tag_frame, mat, u - bar * 0.5, u + bar * 0.5, v0, v1, block_h, block_h + bar)
            pv0, pv1 = tilt_rad >= 0.0 ? [v1 - bar, v1] : [v0, v0 + bar]
            box(ents, geom, 'PV_Треугольник', tag_frame, mat, u - bar * 0.5, u + bar * 0.5, pv0, pv1, block_h + bar, top_z)
            # наклонная сторона треугольника — под панелью, от нижнего края к поднятому
            lo_v, hi_v = tilt_rad >= 0.0 ? [v0, v1] : [v1, v0]
            beam(ents, geom, 'PV_Треугольник', tag_frame, mat, [u, lo_v, base_z - bar * 0.5], [u, hi_v, top_z - bar * 0.5], bar, bar)
            add_line(bom, 'triangle', 1, 'шт', 'angle' => angle)

            block_ratios.each { |r| place_def(ents, geom, ballast_def, tag_ballast, u, v0 + r * proj_v, 0.0) }
            add_line(bom, 'ballast', block_ratios.length, 'шт')

            [0.08, 0.92].each do |r|
              rise = tilt_rad >= 0.0 ? r : 1.0 - r
              place_def(ents, geom, kind == :joint ? w_def : z_def, tag_clamps, u, v0 + r * proj_v, base_z + rise * row_h, tr_tilt)
            end
            add_line(bom, kind == :joint ? 'clampW.bal' : 'clampZ.bal', 2, 'шт', t_sub)
            bom[:kg] += PART_KG[:triangle_south] + 2 * PART_KG[:clamp_bal] + block_ratios.length * cfg['ballastWtKg'].to_f
            link_us << u unless kind == :mid
          end

          seg.each do |cell|
            sv0, sv1 = tilt_rad >= 0.0 ? [v1, v1 + 20.0] : [v0 - 20.0, v0]
            box(ents, geom, 'PV_Спойлер', tag_frame, mat, cell[:u0] + 10.0, cell[:u1] - 10.0, sv0, sv1, block_h, top_z)
          end
          add_line(bom, 'spoiler', seg.length, 'шт')
          bom[:kg] += seg.length * PART_KG[:spoiler]
        end
        row_info << { v0: v0, v1: v1, us: link_us, spans: spans }
      end

      links = row_connectors(ents, geom, cfg, row_info, tag_frame, mat, block_h, bar)
      add_line(bom, 'rowConnector', links, 'шт')
      bom[:kg] += links * PART_KG[:row_connector]
    end

    # Сполучники между соседними рядами: на каждом стыке и конце заднего ряда,
    # если напротив есть передний ряд.
    def self.row_connectors(ents, geom, cfg, row_info, layer, mat, block_h, bar)
      count = 0
      max_gap = cfg['rowGapMm'].to_f + 200.0
      row_info.each_cons(2) do |front, rear|
        gap = rear[:v0] - front[:v1]
        next if gap <= 1.0 || gap > max_gap

        rear[:us].each do |u|
          next unless front[:spans].any? { |a, b| u >= a - 5.0 && u <= b + 5.0 }

          box(ents, geom, 'PV_Сполучник', layer, mat, u - bar * 0.5, u + bar * 0.5, front[:v1], rear[:v0], block_h, block_h + bar)
          count += 1
        end
      end
      count
    end

    # ---------- Balast Схід-Захід: ячейка — «домик» из двух панелей ----------
    # Нормы приняты по аналогии с «Південь» и по картинке: рама на стыках, концах и
    # посередине; три блока на раму; по два прижима на каждую панель у каждой рамы.
    def self.build_ballast_ew(model, ents, cfg, geom, rows, bom)
      width = geom[:proj_v] # ширина домика
      base_z = geom[:base_z]
      thick = cfg['thickMm'].to_f
      t_sub = { 't' => thick.round }
      angle = cfg['triangleAngle'].to_f.round
      ridge_h = cfg['basePanelVMm'].to_f * Math.sin(angle * Math::PI / 180.0)
      block_h = cfg['ballastHMm'].to_f
      bar = 30.0

      tag_frame   = model.layers.add('PV_Профиль')
      tag_clamps  = model.layers.add('PV_Прижимы')
      tag_ballast = model.layers.add('PV_Балласт')
      ballast_def = get_or_create_ballast_def(model, cfg['ballastLMm'].to_f, cfg['ballastWMm'].to_f, block_h)
      z_def = get_or_create_clamp_def(model, "PV_Прижим_Z_#{thick.round}", thick, false)
      w_def = get_or_create_clamp_def(model, "PV_Прижим_W_#{thick.round}", thick, true)
      mat = get_or_create_material(model, 'PV_Aluminum_Rail', [195, 203, 212])

      row_info = []
      rows.each do |row|
        v0 = row.first[:v0]
        v1 = v0 + width
        vm = (v0 + v1) * 0.5
        link_us = []
        spans = []
        LayoutMath.split_series(row, cfg['gapUMm'].to_f).each do |seg|
          spans << [seg.first[:u0], seg.last[:u1]]
          LayoutMath.ballast_lines(seg).each do |u, kind|
            box(ents, geom, 'PV_Рама_СЗ', tag_frame, mat, u - bar * 0.5, u + bar * 0.5, v0, v1, block_h, block_h + bar)
            box(ents, geom, 'PV_Рама_СЗ', tag_frame, mat, u - bar * 0.5, u + bar * 0.5, vm - bar * 0.5, vm + bar * 0.5,
                block_h + bar, base_z + ridge_h)
            # две наклонные стороны рамы — от краёв «домика» к коньку
            ridge = [u, vm, base_z + ridge_h - bar * 0.5]
            beam(ents, geom, 'PV_Рама_СЗ', tag_frame, mat, [u, v0, base_z - bar * 0.5], ridge, bar, bar)
            beam(ents, geom, 'PV_Рама_СЗ', tag_frame, mat, [u, v1, base_z - bar * 0.5], ridge, bar, bar)
            add_line(bom, 'triangleEW', 1, 'шт', 'angle' => angle)

            [0.08, 0.5, 0.92].each { |r| place_def(ents, geom, ballast_def, tag_ballast, u, v0 + r * width, 0.0) }
            add_line(bom, 'ballast', 3, 'шт')

            [[0.04, 0.08], [0.46, 0.92], [0.54, 0.92], [0.96, 0.08]].each do |r, rise|
              place_def(ents, geom, kind == :joint ? w_def : z_def, tag_clamps, u, v0 + r * width, base_z + rise * ridge_h)
            end
            add_line(bom, kind == :joint ? 'clampW.bal' : 'clampZ.bal', 4, 'шт', t_sub)
            # масса рамы Схід-Захід и сполучника неизвестна — в массу не входят
            bom[:kg] += 3 * cfg['ballastWtKg'].to_f + 4 * PART_KG[:clamp_bal]
            link_us << u unless kind == :mid
          end
        end
        row_info << { v0: v0, v1: v1, us: link_us, spans: spans }
      end

      add_line(bom, 'rowConnectorEW', row_connectors(ents, geom, cfg, row_info, tag_frame, mat, block_h, bar), 'шт')
    end

    # ---------- Landing: наземный стол, две панели книгой по высоте ----------
    def self.build_ground(model, ents, cfg, geom, rows, bom)
      tilt_rad = geom[:tilt_rad]
      proj_v = geom[:proj_v]
      row_h = geom[:row_h]
      base_z = geom[:base_z]
      thick = cfg['thickMm'].to_f
      t_sub = { 't' => thick.round }
      slope_len = cfg['panelVMm'].to_f
      near = 439.0
      far = near + 1350.0
      purlin_fracs = [near, far, slope_len - far, slope_len - near].map { |x| x / slope_len }
      post_fracs = [0.172, 0.828] # ряды фундаментов: 2600 мм при глубине стола в плане 3965 мм

      tag_frame  = model.layers.add('PV_Профиль')
      tag_clamps = model.layers.add('PV_Прижимы')
      mid_def = get_or_create_clamp_def(model, "PV_Прижим_П_#{thick.round}", thick, true)
      end_def = get_or_create_clamp_def(model, "PV_Прижим_Z_#{thick.round}", thick, false)
      mat = get_or_create_material(model, 'PV_Aluminum_Rail', [195, 203, 212])
      tr_tilt = Geom::Transformation.rotation(ORIGIN, X_AXIS, tilt_rad)
      height_at = lambda do |frac|
        base_z + (tilt_rad >= 0.0 ? frac : 1.0 - frac) * row_h
      end

      rows.each do |row|
        LayoutMath.split_series(row, cfg['gapUMm'].to_f).each do |seg|
          span = seg.last[:u1] - seg.first[:u0]
          purlin_len = span + GROUND_PURLIN_EXTRA_MM
          table = LayoutMath.ground_table(purlin_len)
          centre = (seg.first[:u0] + seg.last[:u1]) * 0.5
          u_start = centre - purlin_len * 0.5
          v0 = seg.first[:v0]

          purlin_fracs.each do |frac|
            line_v = v0 + frac * proj_v
            z_top = height_at.call(frac)
            box(ents, geom, 'PV_Прогон', tag_frame, mat, u_start, u_start + purlin_len, line_v - 20.5, line_v + 20.5, z_top - 72.0, z_top)
            table[:pieces].each { |len| add_line(bom, 'ground.purlin', 1, 'шт', 'len' => len.round) }
            add_line(bom, 'ground.splice', table[:pieces].length - 1, 'шт')

            [seg.first[:u0] - 12.0, seg.last[:u1] + 12.0].each { |cu| place_def(ents, geom, end_def, tag_clamps, cu, line_v, z_top, tr_tilt) }
            (0...(seg.length - 1)).each do |i|
              place_def(ents, geom, mid_def, tag_clamps, (seg[i][:u1] + seg[i + 1][:u0]) * 0.5, line_v, z_top, tr_tilt)
            end
            add_line(bom, 'clampZ.ground', 2, 'шт', t_sub)
            add_line(bom, 'clampP.ground', seg.length - 1, 'шт', t_sub)
          end

          table[:frames].times do |i|
            fu = u_start + table[:cantilever] + i * table[:spacing]
            post_fracs.each do |frac|
              pv = v0 + frac * proj_v
              box(ents, geom, 'PV_Стойка', tag_frame, mat, fu - 50.0, fu + 50.0, pv - 22.5, pv + 22.5, 0.0, height_at.call(frac) - 72.0)
            end
            # кроква — наклонный брус под прогонами
            beam(ents, geom, 'PV_Кроква', tag_frame, mat,
                 [fu, v0 + 0.05 * proj_v, height_at.call(0.05) - 122.0],
                 [fu, v0 + 0.95 * proj_v, height_at.call(0.95) - 122.0], 45.0, 100.0)
          end
          add_line(bom, 'ground.frame', table[:frames], 'компл')
          add_line(bom, 'ground.embed', table[:frames], 'компл')
          add_line(bom, 'ground.brace', table[:frames] - 1, 'компл')
          add_line(bom, 'ground.concrete', table[:frames] * 2, 'шт')
        end
      end
    end

    # ---------- Сводная спецификация по модели ----------
    def self.aggregate_model_bom
      model = Sketchup.active_model
      summary = {
        'arraysCount' => 0, 'panelsCount' => 0, 'powerKw' => 0.0, 'structureKg' => 0.0,
        'staleCount' => 0, 'legacyCount' => 0, 'items' => [], 'lines' => [],
        'costUsd' => 0.0, 'unpriced' => []
      }
      return summary unless model

      all_lines = []
      each_array_group(model.entities) do |grp|
        data = JSON.parse(grp.get_attribute(ATTR_DICT, 'bom_json'))
        cfg = array_cfg(grp)
        if cfg && panel_instances(grp).length * [cfg['cellPanels'].to_i, 1].max != data['panelsCount'].to_i
          summary['staleCount'] += 1
        end
        summary['arraysCount'] += 1
        summary['panelsCount'] += data['panelsCount'].to_i
        summary['powerKw'] = (summary['powerKw'] + data['powerKw'].to_f).round(2)
        summary['structureKg'] = (summary['structureKg'] + data['structureKg'].to_f).round(1)
        if data['lines'].is_a?(Array)
          all_lines.concat(data['lines'])
        else
          summary['legacyCount'] += 1
        end
        summary['items'] << {
          'groupName' => grp.name, 'panelModel' => data['panelModel'], 'panelSize' => data['panelSize'],
          'orientation' => data['orientation'], 'mountType' => data['mountType'], 'panelsCount' => data['panelsCount']
        }
      end

      nom = load_nomenclature
      prices = load_prices
      factor = price_factor
      order = nom.keys
      merged = merge_lines(all_lines).sort_by do |l|
        [order.index(l['key']) || 999, l['subs'].to_a.map { |_, v| v.to_s.rjust(8, '0') }.join]
      end
      summary['lines'] = merged.map do |l|
        name, note = nom[l['key']].is_a?(Array) ? nom[l['key']] : [l['key'], '']
        name = name.to_s
        note = note.to_s
        l['subs'].each do |k, v|
          name = name.gsub("{#{k}}", v.to_s)
          note = note.gsub("{#{k}}", v.to_s)
        end
        qty = l['qty'].is_a?(Float) ? l['qty'].round(2) : l['qty']
        unit_price, cost, price_note = line_price(l, prices)
        if cost
          cost *= factor
          unit_price *= factor
          summary['costUsd'] += cost
        else
          summary['unpriced'] << name
        end
        { 'name' => name, 'note' => note, 'qty' => qty, 'unit' => l['unit'],
          'price' => unit_price && unit_price.round(2), 'cost' => cost && cost.round(2), 'priceNote' => price_note }
      end
      summary['costUsd'] = summary['costUsd'].round(2)
      summary['priceFactor'] = factor
      summary['priceSource'] = prices['_source'].to_s
      summary
    end

    # Цена строки спецификации по prices.json: [цена за единицу строки, сумма, пояснение] или nil.
    def self.line_price(line, prices)
      entry = prices[line['key']]
      return nil unless entry.is_a?(Hash)

      subs = line['subs'] || {}
      p = entry['price']
      if entry['by']
        v = subs[entry['by']]
        v = v.to_i if v.is_a?(Float) && v == v.round # угол 15.0 -> «15»
        p = (entry['prices'] || {})[v.to_s]
      end
      return nil unless p.is_a?(Numeric)

      qty = line['qty'].to_f
      if entry['per'].to_s == 'м'
        if subs['len']
          unit = p * subs['len'].to_f / 1000.0
          return [unit, unit * qty, nil]
        end
        if entry['pack'].to_f.positive?
          packs = (qty / entry['pack'].to_f).ceil
          return [p, packs * p, "#{packs} рул. по #{entry['pack'].to_f.round} м"]
        end
        return [p, p * qty, nil]
      end
      [p.to_f, p * qty, nil]
    end

    def self.export_bom_to_csv
      bom = aggregate_model_bom
      if bom['arraysCount'].zero?
        UI.messagebox('В модели пока нет размещённых солнечных массивов для выгрузки.')
        return
      end

      model = Sketchup.active_model
      base_name = model && !model.path.empty? ? File.basename(model.path, '.skp') : 'solar_project'
      save_path = UI.savepanel('Сохранить спецификацию СЭС (CSV)', '', "#{base_name}_solar_bom.csv")
      return unless save_path

      File.open(save_path, 'wb:UTF-8') do |file|
        file.write("﻿")
        csv = CSV.new(file, col_sep: ';')
        csv << ['Позиция', 'Характеристика / Модель', 'Количество', 'Ед. изм.', 'Цена, $', 'Сумма, $']
        bom['items'].each do |item|
          csv << ["Солнечная панель (#{item['groupName']})",
                  "#{item['panelModel']} (#{item['panelSize']}, #{item['orientation']}), #{item['mountType']}",
                  item['panelsCount'], 'шт']
        end
        csv << ['Суммарная мощность', 'Все массивы в модели', bom['powerKw'], 'кВт']
        bom['lines'].each do |l|
          note = [l['note'], l['priceNote']].reject { |x| x.to_s.empty? }.join('; ')
          csv << [l['name'], note, l['qty'], l['unit'], l['price'] || 'нет в прайсе', l['cost'] || '']
        end
        unless bom['lines'].empty?
          csv << ['Масса конструкции', 'Крепёж и балластные блоки, только детали с известной массой; без панелей', bom['structureKg'], 'кг']
          factor_note = bom['priceFactor'] == 1.0 ? '' : ", коэффициент #{bom['priceFactor']}"
          csv << ['Стоимость крепежа', "#{bom['priceSource']}#{factor_note}; позиции без цены не входят", '', '', '', bom['costUsd']]
        end
        if bom['legacyCount'].positive?
          csv << ['ВНИМАНИЕ', "Массивов старых версий без состава крепежа: #{bom['legacyCount']} — пересоберите крепёж", '', '']
        end
      end

      UI.messagebox("Спецификация сохранена:\n#{save_path}")
    end
  end
end
