# frozen_string_literal: true

require 'sketchup.rb'
require 'json'
require 'csv'
require_relative 'solar_math'
require_relative 'layout_math'
require_relative 'mounting'

module K2A
  module SolarPlanner
    VERSION = '1.10.2'
    # Ключи данных прежние (были до переименования в K2A): по ним живут уже сделанные модели и настройки
    ATTR_DICT = 'SolarTools_SolarPlanner'
    # Скат с уклоном меньше этого считается плоской кровлей: направление рядов задаётся режимом
    FLAT_PITCH_DEG = 5.0
    # Шаг просмотра ряда вдоль u при поиске свободных участков
    SCAN_STEP_MM = 50.0
    PANEL_DEF_PREFIX = 'PV_Panel_'
    @dialog = nil

    unless file_loaded?(__FILE__)
      cmd = UI::Command.new('K2A Солнечные панели — расстановка') { show_dialog }
      cmd.tooltip = 'Расстановка солнечных панелей'
      cmd.status_bar_text = 'Расстановка солнечных панелей на скаты крыши с обходом препятствий, балластом и спецификацией'

      icon_svg = File.join(__dir__, 'icons', 'tool.svg')
      if File.exist?(icon_svg)
        cmd.small_icon = icon_svg
        cmd.large_icon = icon_svg
      end

      UI.menu('Plugins').add_item(cmd)

      toolbar = UI::Toolbar.new('Солнечные панели')
      toolbar.add_item(cmd)
      toolbar.restore

      UI.add_context_menu_handler do |menu|
        sel = Sketchup.active_model.selection
        if sel.any? { |e| e.is_a?(Sketchup::Face) || e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
          menu.add_item(cmd)
        end
      end

      file_loaded(__FILE__)
    end

    def self.show_dialog
      if @dialog && @dialog.visible?
        @dialog.bring_to_front
        send_model_bom
        return
      end

      @dialog = UI::HtmlDialog.new(
        dialog_title: "K2A Солнечные панели #{VERSION}",
        preferences_key: 'SolarTools_SolarPlanner_v1',
        width: 490,
        height: 820,
        min_width: 440,
        min_height: 620,
        resizable: true,
        style: UI::HtmlDialog::STYLE_DIALOG
      )

      @dialog.set_file(File.join(__dir__, 'dialog.html'))

      @dialog.add_action_callback('ready') do |_ctx|
        send_model_info
        send_model_bom
      end

      @dialog.add_action_callback('place_array') do |_ctx, json_payload|
        begin
          params = JSON.parse(json_payload.to_s)
          place_solar_arrays(params)
        rescue StandardError => e
          UI.messagebox("Ошибка при расстановке панелей:\n#{e.message}")
        end
      end

      @dialog.add_action_callback('recalculate_bom') { |_ctx| send_model_bom }
      @dialog.add_action_callback('export_csv') { |_ctx| export_bom_to_csv }
      @dialog.add_action_callback('add_panel_tool') { |_ctx| start_add_panel_tool }
      @dialog.add_action_callback('rebuild_mounting') do |_ctx, json_payload|
        params = begin
          json_payload.to_s.empty? ? nil : JSON.parse(json_payload.to_s)
        rescue JSON::ParserError
          nil
        end
        rebuild_selected_arrays(params)
      end

      @dialog.show
    end

    # Собираем все выбранные грани: либо напрямую выделенные Face (можно несколько через Shift),
    # либо верхние грани крыши внутри выделенной группы/компонента крыши.
    def self.collect_target_faces(model)
      targets = []
      sel = model.selection

      direct_faces = sel.grep(Sketchup::Face)
      unless direct_faces.empty?
        direct_faces.each do |face|
          targets << { face: face, tr: Geom::Transformation.new, container: nil }
        end
        return targets
      end

      sel.each do |ent|
        next unless ent.is_a?(Sketchup::Group) || ent.is_a?(Sketchup::ComponentInstance)
        next if ent.get_attribute(ATTR_DICT, 'bom_json')

        collect_roof_faces_recursive(ent, Geom::Transformation.new, ent, targets)
      end
      targets
    end

    def self.collect_roof_faces_recursive(container, parent_tr, root_container, targets)
      tr = parent_tr * container.transformation
      container.definition.entities.each do |ent|
        if ent.is_a?(Sketchup::Face)
          world_n = world_normal(ent, tr)
          world_n.reverse! if world_n.dot(ent.normal.transform(tr)) < 0.0
          # Берём скаты и плоские кровли: направлены вверх, площадь от 1 м²,
          # не на уровне низа группы и не под перекрытием
          area_m2 = ent.area * (0.0254 * 0.0254)
          if world_n.z > 0.15 && area_m2 >= 1.0 && roof_face_exposed?(ent, tr, world_n, root_container)
            targets << { face: ent, tr: tr, container: root_container }
          end
        elsif ent.is_a?(Sketchup::Group) || ent.is_a?(Sketchup::ComponentInstance)
          # массив панелей и сами панели — не скаты: иначе верх панелей уходит под новую раскладку
          next if solar_entity?(ent)

          collect_roof_faces_recursive(ent, tr, root_container, targets)
        end
      end
    end

    # Группа массива или экземпляр панели (в том числе ячейка «домика» и стола).
    def self.solar_entity?(ent)
      return true if ent.respond_to?(:get_attribute) &&
                     (ent.get_attribute(ATTR_DICT, 'cfg_json') || ent.get_attribute(ATTR_DICT, 'bom_json'))

      ent.is_a?(Sketchup::ComponentInstance) && ent.definition.name.start_with?(PANEL_DEF_PREFIX)
    end

    # Грань годится под панели: не земля/пол на уровне низа группы и над ней нет перекрытия.
    # Уже стоящие панели перекрытием не считаются — иначе скат под массивом не найти для замены.
    def self.roof_face_exposed?(face, tr, world_n, root_container)
      zs = face.vertices.map { |vtx| vtx.position.transform(tr).z }
      bb = root_container.bounds
      return false if bb.depth.to_mm > 1000.0 && (zs.max - bb.min.z).to_mm < 100.0

      mesh = face.mesh
      count = mesh.count_polygons
      return true if count.zero?

      # три пробные точки: препятствие на кровле над одной из них не должно выбросить весь скат
      [1, (count + 1) / 2, count].uniq.any? do |idx|
        pts = mesh.polygon_points_at(idx)
        next true unless pts && pts.length >= 3

        centre = Geom::Point3d.new(
          (pts[0].x + pts[1].x + pts[2].x) / 3.0,
          (pts[0].y + pts[1].y + pts[2].y) / 3.0,
          (pts[0].z + pts[1].z + pts[2].z) / 3.0
        ).transform(tr)
        hit = Sketchup.active_model.raytest([centre.offset(world_n, 50.mm), Z_AXIS], true)
        hit.nil? || (hit[0].z - centre.z).to_mm > 20_000.0 || hit[1].any? { |e| solar_entity?(e) }
      end
    end

    # Массивы в корне модели, панели которых стоят на этой грани.
    def self.arrays_on_face(model, face, face_tr)
      n_axis = world_normal(face, face_tr)
      plane_pt = face.vertices.first.position.transform(face_tr)
      face_tr_inv = face_tr.inverse
      arrays_with_cfg(model).select do |grp|
        next false unless grp.parent == model

        cfg = array_cfg(grp)
        next false unless cfg

        geom = array_geom(cfg)
        tr = grp.transformation
        next false unless geom[:n].transform(tr).parallel?(n_axis)
        next false if (geom[:origin].transform(tr) - plane_pt).dot(n_axis).to_mm.abs > 2.0

        array_cells(grp, cfg, geom).any? do |c|
          centre = point_on_basis(
            geom[:origin], geom[:u], geom[:v], geom[:n],
            (c[:u0] + c[:u1]) * 0.5, (c[:v0] + c[:v1]) * 0.5, 0.0
          )
          local = centre.transform(tr).transform(face_tr_inv).project_to_plane(face.plane)
          INSIDE_FLAGS.include?(face.classify_point(local))
        end
      end
    end

    def self.place_solar_arrays(params)
      model = Sketchup.active_model
      return unless model

      targets = collect_target_faces(model)
      if targets.empty?
        UI.messagebox('Выделите один или несколько скатов крыши (грани Face) либо группу модели крыши, затем нажмите «Разместить на крыше».')
        return
      end

      length_mm   = [params['lengthMm'].to_f, 200.0].max
      width_mm    = [params['widthMm'].to_f, 200.0].max
      thick_mm    = [params['thicknessMm'].to_f, 10.0].max
      power_w     = [params['powerW'].to_f, 0.0].max
      model_name  = params['panelModel'].to_s.strip
      model_name  = 'PV Panel' if model_name.empty?

      orientation   = params['orientation'].to_s == 'landscape' ? 'landscape' : 'portrait'
      gap_u_mm      = [params['gapUMm'].to_f, 0.0].max
      row_gap_mode  = params['rowGapMode'].to_s
      manual_gap_v  = [params['gapVMm'].to_f, 0.0].max
      latitude_deg  = params['latitudeDeg'].to_f
      margin_mm     = [params['edgeMarginMm'].to_f, 0.0].max
      obs_clear_mm  = [params['obstacleClearanceMm'].to_f, 0.0].max
      tilt_mode     = params['tiltMode'].to_s
      tilt_deg      = params['tiltDeg'].to_f
      standoff_mm   = [params['standoffMm'].to_f, 20.0].max

      mount_type       = %w[ballast ballast_ew ground block].include?(params['mountType'].to_s) ? params['mountType'].to_s : 'rail_clamp'
      rail_profile     = params['railProfile'].to_s == 'g41' ? 'g41' : 'al_ld'
      anchor_type      = %w[l45 tbit ubit falz hook screw].include?(params['anchorType'].to_s) ? params['anchorType'].to_s : 'l45'
      rail_dir         = params['railDir'].to_s == 'across' ? 'across' : 'along'
      rail_lines       = params['railLines'].to_i == 3 ? 3 : 2
      rows_per_strip   = [[params['rowsPerStrip'].to_i, 1].max, 10].min
      aisle_mm         = [params['aisleMm'].to_f, 0.0].max
      include_mounting = params['includeMounting'] == true
      rail_stock_mm    = [params['railStockMm'].to_f, 1000.0].max
      bracket_step_mm  = [params['bracketStepMm'].to_f, 300.0].max
      rail_overhang_mm = [params['railOverhangMm'].to_f, 0.0].max

      ballast_l_mm     = [params['ballastLengthMm'].to_f, 100.0].max
      ballast_w_mm     = [params['ballastWidthMm'].to_f, 80.0].max
      ballast_h_mm     = [params['ballastHeightMm'].to_f, 30.0].max
      ballast_wt_kg    = [params['ballastWeightKg'].to_f, 1.0].max
      # Блоков на линию опор (стык панелей или конец серии): 2 — под каждым профилем, 3 — ещё один посередине
      ballast_per_joint = [[params['ballastPerJoint'].to_i, 2].max, 3].min
      ballast_angle = params['ballastAngleDeg'].to_i == 20 ? 20.0 : 15.0
      # Balast Південь: панель альбомом на трёх треугольниках
      # Системы с заданной ориентацией панели и наклоном
      forced = nil
      block_note = nil
      if %w[ballast ballast_ew].include?(mount_type)
        forced = 'альбомом' if orientation != 'landscape'
        orientation = 'landscape'
      elsif mount_type == 'block'
        # беспрофильная: панель лежит на блоках по профнастилу, без наклона; зазор кровли — высота блока
        if tilt_mode != 'flush' || (standoff_mm - BLOCK_H_MM).abs > 1.0
          block_note = "#{SYSTEM_LABELS['block']}: панели лежат на блоках #{BLOCK_H_MM.round} мм без наклона — наклон и зазор кровли не применяются"
        end
        tilt_mode = 'flush'
        standoff_mm = BLOCK_H_MM
      elsif mount_type == 'ground'
        forced = 'книгой' if orientation != 'portrait'
        orientation = 'portrait'
        tilt_mode = 'ground_tilt'
        tilt_deg = GROUND_TILT_DEG
        standoff_mm = GROUND_LOW_EDGE_MM
      end

      latitude_deg  = [[latitude_deg, 0.0].max, 75.0].min
      win_start_h   = [[params['windowStartH'].to_f, 6.0].max, 12.0].min
      win_end_h     = [[params['windowEndH'].to_f, 12.0].max, 18.0].min
      row_orient    = params['rowOrientMode'].to_s
      row_azimuth   = params['rowAzimuthDeg'].to_f

      # Север модели: NorthAngle — по часовой стрелке от оси Y
      north_angle_deg = model.shadow_info['NorthAngle'].to_f
      nxy = SolarMath.north_xy(north_angle_deg)
      north_vec = Geom::Vector3d.new(nxy[0], nxy[1], 0)
      east_vec  = Geom::Vector3d.new(nxy[1], -nxy[0], 0)
      south_vec = north_vec.reverse
      report = []
      report << "#{SYSTEM_LABELS[mount_type]} ставится только #{forced} — ориентация изменена" if forced
      report << block_note if block_note

      if orientation == 'landscape'
        panel_u_mm = [length_mm, width_mm].max
        panel_v_mm = [length_mm, width_mm].min
      else
        panel_u_mm = [length_mm, width_mm].min
        panel_v_mm = [length_mm, width_mm].max
      end

      # Ячейка раскладки: одна панель, либо две — стол наземной системы (панели друг над другом
      # по скату) или «домик» восток–запад. Дальше panel_v_mm — размер ячейки.
      base_v_mm = panel_v_mm
      cell_panels = 1
      if mount_type == 'ground'
        panel_v_mm = 2.0 * base_v_mm + GROUND_ROW_GAP_MM
        cell_panels = 2
      elsif mount_type == 'ballast_ew'
        panel_v_mm = 2.0 * base_v_mm * Math.cos(ballast_angle * Math::PI / 180.0) + EW_RIDGE_GAP_MM
        cell_panels = 2
      end

      existing = targets.flat_map { |t| arrays_on_face(model, t[:face], t[:tr]) }.uniq
      replace_existing = false
      unless existing.empty?
        answer = UI.messagebox(
          "На выбранных скатах уже стоят массивы: #{existing.length}.\n\n" \
          "Да — заменить их новой раскладкой.\n" \
          'Нет — оставить и добавить панели только в свободные места.',
          MB_YESNOCANCEL
        )
        return if answer == IDCANCEL

        replace_existing = (answer == IDYES)
      end

      model.start_operation('Расстановка солнечных панелей', true)
      placed_total = 0

      begin
        if replace_existing
          model.entities.erase_entities(existing)
          report << "Заменено массивов: #{existing.length}"
        end
        tag_panels = model.layers.add('PV_Панели')
        panel_def  = get_or_create_cell_def(model, model_name, panel_u_mm, base_v_mm, thick_mm, mount_type, ballast_angle)

        targets.each_with_index do |target, face_idx|
          face = target[:face]
          face_tr = target[:tr]
          face_tr_inv = face_tr.inverse
          roof_container = target[:container]

          n_axis = world_normal(face, face_tr)
          n_axis.reverse! if n_axis.z < 0.0

          roof_pitch_rad = Math.acos([[n_axis.z, -1.0].max, 1.0].min)
          roof_pitch_deg = roof_pitch_rad * 180.0 / Math::PI
          is_flat = roof_pitch_deg < FLAT_PITCH_DEG
          face_mount = mount_type
          if %w[ballast ballast_ew].include?(mount_type) && !is_flat
            report << "Скат #{face_idx + 1}: #{SYSTEM_LABELS[mount_type]} ставится только на плоскую кровлю — пропущен"
            next
          end

          if is_flat
            u_axis, v_axis = flat_basis(model, face, face_tr, n_axis, north_vec, east_vec, row_orient, row_azimuth)
          else
            u_axis = Z_AXIS.cross(n_axis).normalize
            v_axis = n_axis.cross(u_axis).normalize
          end

          # Скат смотрит в северную половину: панель наклоняется к югу, поднимается нижний по скату край
          slope_dir = Geom::Vector3d.new(n_axis.x, n_axis.y, 0)
          faces_north = !is_flat && slope_dir.length > 1.0e-9 && slope_dir.normalize.dot(south_vec) < -0.087

          # Знак наклона: > 0 — поднят верхний по v край, < 0 — нижний.
          # Наклон панели к горизонту после поворота вокруг u равен (уклон вдоль v + локальный наклон).
          tilt_req = [[tilt_deg, 0.0].max, 75.0].min
          local_tilt_deg = case tilt_mode
                           when 'roof_tilt'
                             faces_north ? -tilt_req : tilt_req
                           when 'ground_tilt'
                             if is_flat
                               v_pitch_deg = Math.asin([[v_axis.z, -1.0].max, 1.0].min) * 180.0 / Math::PI
                               [tilt_req - v_pitch_deg, 0.0].max
                             elsif faces_north
                               -[tilt_req + roof_pitch_deg, 75.0].min
                             else
                               [tilt_req - roof_pitch_deg, 0.0].max
                             end
                           else
                             0.0
                           end
          local_tilt_deg = ballast_angle if face_mount == 'ballast'
          local_tilt_deg = 0.0 if face_mount == 'ballast_ew' # наклон — внутри ячейки-«домика»
          local_tilt_rad = local_tilt_deg * Math::PI / 180.0
          tilt_abs_rad = local_tilt_rad.abs

          proj_v_mm = panel_v_mm * Math.cos(tilt_abs_rad)
          row_h_mm  = panel_v_mm * Math.sin(tilt_abs_rad)

          # Зазор между рядами: по солнцу (21 декабря, расчётное окно) или вручную
          gap_v_mm = manual_gap_v
          gap_note = 'зазор ручной'
          if local_tilt_deg.abs > 0.5
            res = SolarMath.row_gap(
              lat_deg: latitude_deg, north_angle_deg: north_angle_deg,
              v_axis: v_axis.to_a, n_axis: n_axis.to_a,
              high_mm: row_h_mm, proj_mm: proj_v_mm,
              tilt_sign: local_tilt_deg.negative? ? -1 : 1,
              t_start_h: win_start_h, t_end_h: win_end_h
            )
            if row_gap_mode != 'solar_shadow'
              if res[:lit].positive? && res[:gap_mm] > manual_gap_v + 1.0
                gap_note = format(
                  'зазор заданный; ВНИМАНИЕ: по солнцу на 21 дек. в окне нужно %d мм — ряды в окне затеняют друг друга',
                  res[:gap_mm].round
                )
              end
            elsif res[:lit].zero?
              gap_note = 'ВНИМАНИЕ: скат не освещён в расчётном окне 21 дек., расчёт по солнцу неприменим, взят ручной зазор'
            else
              gap_v_mm = [res[:gap_mm], 100.0].max
              wh = res[:worst_h] || 12.0
              gap_note = format('зазор по солнцу, худший момент %d:%02d солн.', wh.floor, ((wh - wh.floor) * 60).round)
              if res[:lit] < res[:total]
                gap_note += format('; ВНИМАНИЕ: скат освещён только %d%% окна', (100.0 * res[:lit] / res[:total]).round)
              end
            end
          end
          face_report = format(
            'Скат %d: уклон %.1f°, наклон панели к кровле %.1f°, зазор между рядами %d мм (%s)',
            face_idx + 1, roof_pitch_deg, local_tilt_deg, gap_v_mm.round, gap_note
          )

          step_u_mm = panel_u_mm + gap_u_mm

          origin = face.vertices.first.position.transform(face_tr)
          u_coords = []
          v_coords = []
          face.outer_loop.vertices.each do |vtx|
            vec = vtx.position.transform(face_tr) - origin
            u_coords << vec.dot(u_axis).to_mm
            v_coords << vec.dot(v_axis).to_mm
          end

          min_u = u_coords.min + margin_mm
          max_u = u_coords.max - margin_mm
          min_v = v_coords.min + margin_mm
          max_v = v_coords.max - margin_mm

          next if (max_u - min_u) < panel_u_mm || (max_v - min_v) < proj_v_mm

          cols_possible = ((max_u - min_u + gap_u_mm) / step_u_mm).floor
          # ряды: подряд либо полосами по rows_per_strip с проходом между полосами
          row_offs = LayoutMath.row_offsets(max_v - min_v, proj_v_mm, gap_v_mm, rows_per_strip, aisle_mm)
          rows_possible = row_offs.length
          next if cols_possible <= 0 || rows_possible <= 0

          span_u = cols_possible * panel_u_mm + [cols_possible - 1, 0].max * gap_u_mm
          span_v = row_offs.last + proj_v_mm

          start_u = min_u + ((max_u - min_u) - span_u) * 0.5
          start_v = min_v + ((max_v - min_v) - span_v) * 0.5

          valid_rows = []
          rows_possible.times do |r|
            v0 = start_v + row_offs[r]
            v1 = v0 + proj_v_mm
            Sketchup.status_text = "Солнечные панели: скат #{face_idx + 1}, ряд #{r + 1} из #{rows_possible}"
            runs = row_panel_runs(
              model, face, face_tr_inv, origin, u_axis, v_axis, n_axis,
              u_coords.min, u_coords.max, v0, v1,
              panel_u_mm, step_u_mm, start_u, margin_mm, obs_clear_mm
            )
            row_cols = []
            col = 0
            runs.each do |run|
              run.each do |u0|
                row_cols << { col: col, u0: u0, u1: u0 + panel_u_mm, v0: v0, v1: v1 }
                col += 1
              end
              col += 1 # разрыв между сериями: профиль не идёт через препятствие
            end
            valid_rows << row_cols unless row_cols.empty?
          end

          face_panels_count = valid_rows.sum(&:length)
          if face_panels_count.zero?
            report << "Скат #{face_idx + 1}: панели не поместились"
            next
          end
          face_panels_count *= cell_panels
          report << "#{face_report}, панелей #{face_panels_count}"

          placed_total += face_panels_count

          array_group = model.active_entities.add_group
          name_prefix = "PV_Скат#{face_idx + 1}_#{model_name}"
          array_group.name = "#{name_prefix}_#{face_panels_count}шт"

          # Параметры массива хранятся на группе: по ним крепёж пересобирается
          # и добавляются панели вручную. Координаты — внутренние координаты группы.
          cfg = {
            'namePrefix' => name_prefix,
            'panelDef' => panel_def.name,
            'panelModel' => model_name,
            'panelSize' => "#{length_mm.round}×#{width_mm.round}×#{thick_mm.round} мм",
            'orientation' => orientation == 'landscape' ? 'Альбом' : 'Книга',
            'powerW' => power_w,
            'origin' => origin.to_a.map(&:to_f),
            'u' => u_axis.to_a.map(&:to_f),
            'v' => v_axis.to_a.map(&:to_f),
            'n' => n_axis.to_a.map(&:to_f),
            'panelUMm' => panel_u_mm,
            'panelVMm' => panel_v_mm,
            'thickMm' => thick_mm,
            'localTiltDeg' => local_tilt_deg,
            'gapUMm' => gap_u_mm,
            'rowGapMm' => gap_v_mm,
            'standoffMm' => standoff_mm,
            'mount' => face_mount,
            'cellPanels' => cell_panels,
            'basePanelVMm' => base_v_mm,
            'triangleAngle' => ballast_angle,
            'profile' => rail_profile,
            'anchor' => anchor_type,
            'railDir' => rail_dir,
            'railLines' => rail_lines,
            'rowsPerStrip' => rows_per_strip,
            'aisleMm' => aisle_mm,
            'includeMounting' => include_mounting,
            'railStockMm' => rail_stock_mm,
            'bracketStepMm' => bracket_step_mm,
            'railOverhangMm' => rail_overhang_mm,
            'ballastLMm' => ballast_l_mm,
            'ballastWMm' => ballast_w_mm,
            'ballastHMm' => ballast_h_mm,
            'ballastWtKg' => ballast_wt_kg,
            'ballastPerJoint' => ballast_per_joint
          }
          geom = array_geom(cfg)
          valid_rows.each do |row_cells|
            row_cells.each do |cell|
              inst = array_group.entities.add_instance(panel_def, panel_transform(geom, cfg, cell[:u0], cell[:v0]))
              inst.layer = tag_panels
            end
          end
          array_group.set_attribute(ATTR_DICT, 'cfg_json', JSON.generate(cfg))
          rebuild_array(model, array_group)
        end

        if placed_total.zero?
          model.abort_operation
          send_report(report)
          UI.messagebox('Не удалось разместить панели на выбранных скатах (проверьте размеры ската, отступы или препятствия).')
          return
        end

        model.commit_operation
        send_report(report)
        send_model_bom
      rescue StandardError => e
        model.abort_operation
        raise e
      end
    end

    # Нормаль грани в координатах модели. Считается по преобразованным точкам:
    # прямое преобразование вектора нормали неверно при неравномерном масштабе.
    def self.world_normal(face, tr)
      p0 = face.vertices.first.position
      ax = face.normal.axes
      w0 = p0.transform(tr)
      w1 = p0.offset(ax[0]).transform(tr)
      w2 = p0.offset(ax[1]).transform(tr)
      (w1 - w0).cross(w2 - w0).normalize
    end

    # Базис рядов на плоской кровле: u — вдоль ряда, v — поперёк (в сторону поднятого края).
    # Режимы: 'cardinal' — по сторонам света (панели на юг), 'azimuth' — заданный азимут панелей,
    # иначе — вдоль ребра: выделенного ребра грани либо самого длинного ребра контура.
    def self.flat_basis(model, face, face_tr, n_axis, north_vec, east_vec, mode, azimuth_deg)
      u_dir = case mode
              when 'cardinal'
                east_vec
              when 'azimuth'
                a = azimuth_deg * Math::PI / 180.0
                facing = Geom::Vector3d.new(
                  north_vec.x * Math.cos(a) + east_vec.x * Math.sin(a),
                  north_vec.y * Math.cos(a) + east_vec.y * Math.sin(a),
                  0
                )
                facing.reverse.cross(Z_AXIS)
              else
                edge_direction(model, face, face_tr) || east_vec
              end

      d = u_dir.dot(n_axis)
      u = Geom::Vector3d.new(u_dir.x - n_axis.x * d, u_dir.y - n_axis.y * d, u_dir.z - n_axis.z * d).normalize
      v = n_axis.cross(u).normalize

      unless %w[cardinal azimuth].include?(mode)
        # вдоль ребра: поднятый край — тот, что севернее (панели смотрят в южную половину)
        vn = v.dot(north_vec)
        if vn < -1.0e-6 || (vn.abs <= 1.0e-6 && v.dot(east_vec) < 0.0)
          u.reverse!
          v.reverse!
        end
      end
      [u, v]
    end

    def self.edge_direction(model, face, face_tr)
      world_len = lambda do |e|
        e.start.position.transform(face_tr).distance(e.end.position.transform(face_tr))
      end
      selected = model.selection.grep(Sketchup::Edge).select { |e| e.faces.include?(face) }
      pool = selected.empty? ? face.outer_loop.edges : selected
      edge = pool.max_by { |e| world_len.call(e) }
      return nil unless edge

      vec = edge.end.position.transform(face_tr) - edge.start.position.transform(face_tr)
      vec.length > 0 ? vec.normalize : nil
    end

    # ---------- Настройки вне кода: база панелей и названия позиций спецификации ----------

    # Папка настроек пользователя. Файлы в ней не затираются при обновлении расширения.
    # Имя папки прежнее: в ней уже лежат база панелей и названия позиций пользователя.
    def self.config_dir
      dir = File.join(ENV['APPDATA'] || Dir.home, 'SolarPlanner')
      Dir.mkdir(dir) unless Dir.exist?(dir)
      dir
    rescue StandardError
      __dir__
    end

    def self.config_file(name)
      bundled = File.join(__dir__, name)
      user = File.join(config_dir, name)
      return user if File.exist?(user)

      File.write(user, File.read(bundled, encoding: 'UTF-8'), encoding: 'UTF-8')
      user
    rescue StandardError
      bundled
    end

    def self.load_json_config(name, fallback)
      JSON.parse(File.read(config_file(name), encoding: 'UTF-8'))
    rescue StandardError => e
      puts "[K2A Солнечные панели] #{name}: #{e.message}"
      fallback
    end

    # Названия позиций: встроенный файл — основа, файл пользователя перекрывает.
    # Устаревший файл пользователя (меньший номер версии) сохраняется как .bak и заменяется новым.
    def self.load_nomenclature
      bundled_path = File.join(__dir__, 'nomenclature.json')
      bundled = JSON.parse(File.read(bundled_path, encoding: 'UTF-8'))
      user_path = config_file('nomenclature.json')
      return bundled if user_path == bundled_path

      user = JSON.parse(File.read(user_path, encoding: 'UTF-8'))
      if user['_version'].to_i < bundled['_version'].to_i
        bak = "#{user_path}.bak"
        File.delete(bak) if File.exist?(bak)
        File.rename(user_path, bak)
        File.write(user_path, File.read(bundled_path, encoding: 'UTF-8'), encoding: 'UTF-8')
        return bundled
      end
      bundled.merge(user)
    rescue StandardError => e
      puts "[K2A Солнечные панели] nomenclature.json: #{e.message}"
      {}
    end

    def self.send_model_info
      return unless @dialog && @dialog.visible?

      model = Sketchup.active_model
      return unless model

      si = model.shadow_info
      info = {
        'georeferenced' => model.georeferenced?,
        'latitude' => si['Latitude'].to_f.round(2),
        'northAngle' => si['NorthAngle'].to_f.round(1),
        'panels' => load_json_config('panels.json', []),
        'configDir' => config_dir
      }
      @dialog.execute_script("window.setModelInfo(#{JSON.generate(info)});")
    end

    def self.send_report(lines)
      lines.each { |l| puts "[K2A Солнечные панели] #{l}" }
      return unless @dialog && @dialog.visible?

      @dialog.execute_script("window.showPlacementReport(#{JSON.generate(lines)});")
    end

    # ---------- Массив: параметры, панели, крепёж ----------

    # Все группы массивов в модели, включая вложенные в другие группы.
    def self.each_array_group(entities, depth = 0, &block)
      entities.grep(Sketchup::Group).each do |grp|
        if grp.get_attribute(ATTR_DICT, 'bom_json')
          yield grp
        elsif depth < 6
          each_array_group(grp.entities, depth + 1, &block)
        end
      end
    end

    def self.array_cfg(group)
      raw = group.get_attribute(ATTR_DICT, 'cfg_json')
      raw ? JSON.parse(raw) : nil
    rescue JSON::ParserError
      nil
    end

    def self.array_geom(cfg)
      tilt_rad = cfg['localTiltDeg'].to_f * Math::PI / 180.0
      panel_v = cfg['panelVMm'].to_f
      standoff = cfg['standoffMm'].to_f
      {
        origin: Geom::Point3d.new(cfg['origin']),
        u: Geom::Vector3d.new(cfg['u']),
        v: Geom::Vector3d.new(cfg['v']),
        n: Geom::Vector3d.new(cfg['n']),
        tilt_rad: tilt_rad,
        proj_v: panel_v * Math.cos(tilt_rad.abs),
        row_h: panel_v * Math.sin(tilt_rad.abs),
        base_z: %w[ballast ballast_ew].include?(cfg['mount']) ? standoff + cfg['ballastHMm'].to_f : standoff
      }
    end

    # Положение панели: u0, v0 — левый нижний (по v) угол её проекции на скат.
    def self.panel_transform(geom, cfg, u0, v0)
      tr_tilt = Geom::Transformation.rotation(ORIGIN, X_AXIS, geom[:tilt_rad])
      if geom[:tilt_rad] >= 0.0
        # ось поворота — нижний по v край панели
        pt = point_on_basis(geom[:origin], geom[:u], geom[:v], geom[:n], u0, v0, geom[:base_z])
        Geom::Transformation.axes(pt, geom[:u], geom[:v], geom[:n]) * tr_tilt
      else
        # ось поворота — верхний по v край, поднимается нижний
        pt = point_on_basis(geom[:origin], geom[:u], geom[:v], geom[:n], u0, v0 + geom[:proj_v], geom[:base_z])
        tr_shift = Geom::Transformation.translation(Geom::Vector3d.new(0, -cfg['panelVMm'].to_f.mm, 0))
        Geom::Transformation.axes(pt, geom[:u], geom[:v], geom[:n]) * tr_tilt * tr_shift
      end
    end

    def self.panel_instances(group)
      group.entities.grep(Sketchup::ComponentInstance).select do |inst|
        inst.definition.name.start_with?(PANEL_DEF_PREFIX)
      end
    end

    # Фактические панели массива в координатах u, v ската.
    def self.array_cells(group, cfg, geom)
      panel_u = cfg['panelUMm'].to_f
      panel_instances(group).map do |inst|
        d = inst.transformation.origin - geom[:origin]
        u0 = d.dot(geom[:u]).to_mm
        v0 = d.dot(geom[:v]).to_mm
        { u0: u0, u1: u0 + panel_u, v0: v0, v1: v0 + geom[:proj_v] }
      end
    end

    # ---------- Команды: пересборка крепежа, ручное добавление панелей ----------

    def self.arrays_with_cfg(model)
      list = []
      each_array_group(model.entities) { |grp| list << grp if grp.get_attribute(ATTR_DICT, 'cfg_json') }
      list
    end

    def self.selected_arrays(model)
      model.selection.grep(Sketchup::Group).select { |grp| grp.get_attribute(ATTR_DICT, 'cfg_json') }
    end

    # Настройки крепежа из окна, которые меняются без перерасстановки панелей.
    # Ограничения — те же, что при расстановке (place_solar_arrays).
    def self.mount_settings(params)
      {
        'mount' => %w[ballast ballast_ew ground block].include?(params['mountType'].to_s) ? params['mountType'].to_s : 'rail_clamp',
        'includeMounting' => params['includeMounting'] == true,
        'profile' => params['railProfile'].to_s == 'g41' ? 'g41' : 'al_ld',
        'anchor' => %w[l45 tbit ubit falz hook screw].include?(params['anchorType'].to_s) ? params['anchorType'].to_s : 'l45',
        'railDir' => params['railDir'].to_s == 'across' ? 'across' : 'along',
        'railLines' => params['railLines'].to_i == 3 ? 3 : 2,
        'bracketStepMm' => [params['bracketStepMm'].to_f, 300.0].max,
        'railOverhangMm' => [params['railOverhangMm'].to_f, 0.0].max,
        'standoffMm' => [params['standoffMm'].to_f, 20.0].max,
        'ballastLMm' => [params['ballastLengthMm'].to_f, 100.0].max,
        'ballastWMm' => [params['ballastWidthMm'].to_f, 80.0].max,
        'ballastHMm' => [params['ballastHeightMm'].to_f, 30.0].max,
        'ballastWtKg' => [params['ballastWeightKg'].to_f, 1.0].max,
        'ballastPerJoint' => [[params['ballastPerJoint'].to_i, 2].max, 3].min
      }
    end

    # Смена системы без перерасстановки возможна, только если панели остаются теми же и там же по скату:
    # скатная ↔ Block при панелях без наклона. У балластных и наземной своя ячейка, ориентация и наклон.
    # Возвращает nil, если можно, иначе — причину.
    def self.mount_switch_problem(cfg, new_mount)
      old_mount = cfg['mount'].to_s
      return nil if old_mount == new_mount

      flat = %w[rail_clamp block]
      unless flat.include?(old_mount) && flat.include?(new_mount)
        return "смена «#{SYSTEM_LABELS[old_mount] || old_mount}» → «#{SYSTEM_LABELS[new_mount] || new_mount}» меняет раскладку панелей"
      end
      if new_mount == 'block' && cfg['localTiltDeg'].to_f.abs > 0.01
        return "#{SYSTEM_LABELS['block']} — только для панелей без наклона, а здесь наклон #{cfg['localTiltDeg'].to_f.round(1)}°"
      end

      nil
    end

    # Применить настройки окна к массиву: cfg обновляется, панели сдвигаются по нормали,
    # если поменялась высота над кровлей (зазор кровли, высота балластного блока, Block).
    def self.apply_mount_settings(group, cfg, settings)
      old_geom = array_geom(cfg)
      cells = array_cells(group, cfg, old_geom)
      new_cfg = cfg.merge(settings)
      new_cfg['standoffMm'] = BLOCK_H_MM if new_cfg['mount'] == 'block'
      new_cfg['standoffMm'] = GROUND_LOW_EDGE_MM if new_cfg['mount'] == 'ground'
      new_geom = array_geom(new_cfg)
      if (new_geom[:base_z] - old_geom[:base_z]).abs > 0.01
        panel_instances(group).zip(cells).each do |inst, cell|
          inst.transformation = panel_transform(new_geom, new_cfg, cell[:u0], cell[:v0])
        end
      end
      group.set_attribute(ATTR_DICT, 'cfg_json', JSON.generate(new_cfg))
      new_cfg
    end

    # Пересборка крепежа. С настройками окна (params) — по ним: система (в пределах mount_switch_problem),
    # профиль, крепление, шаг опор, зазор кровли, балласт. Настройки окна применяются к выделенным массивам,
    # а если не выделено ничего — к единственному массиву модели; при нескольких невыделенных каждый
    # пересобирается по своим сохранённым настройкам.
    def self.rebuild_selected_arrays(params = nil)
      model = Sketchup.active_model
      return unless model

      arrays = selected_arrays(model)
      apply = !arrays.empty?
      if arrays.empty?
        arrays = arrays_with_cfg(model)
        apply = arrays.length == 1
      end
      if arrays.empty?
        UI.messagebox('Нет массивов, которые можно пересобрать. Массивы, созданные версиями до 1.4.0, нужно разместить заново.')
        return
      end
      settings = params && apply ? mount_settings(params) : nil

      report = []
      model.start_operation('Пересобрать крепёж', true)
      begin
        arrays.each do |grp|
          if settings
            cfg = array_cfg(grp)
            problem = cfg && mount_switch_problem(cfg, settings['mount'])
            if problem
              report << "#{grp.name}: не пересобран — #{problem}. Разместите массив заново (выделите скат, «Разместить» заменит панели)."
              next
            end
            old_mount = cfg['mount'].to_s
            apply_mount_settings(grp, cfg, settings) if cfg
            rebuild_array(model, grp)
            changed = old_mount == settings['mount'] ? '' : " (система: #{SYSTEM_LABELS[settings['mount']]})"
            report << "Пересобран крепёж по настройкам окна: #{grp.name}#{changed}"
          else
            rebuild_array(model, grp)
            report << "Пересобран крепёж по сохранённым настройкам: #{grp.name}"
          end
        end
        model.commit_operation
      rescue StandardError => e
        model.abort_operation
        UI.messagebox("Ошибка при пересборке крепежа:\n#{e.message}")
        return
      end
      if params && !apply
        report << 'Настройки окна не применены: массивов несколько, а выделенных нет. Выделите массивы, к которым их применить.'
      end
      send_report(report)
      send_model_bom
    end

    def self.start_add_panel_tool
      model = Sketchup.active_model
      return unless model

      arrays = selected_arrays(model)
      if arrays.empty?
        all = arrays_with_cfg(model)
        arrays = all if all.length == 1
      end
      if arrays.length != 1
        UI.messagebox("Выделите один массив панелей (группу «PV_Скат…»), в который добавлять панели.\nМассивы, созданные версиями до 1.4.0, нужно разместить заново.")
        return
      end
      model.select_tool(AddPanelTool.new(arrays.first, array_cfg(arrays.first)))
    end

    # Инструмент: щелчок по плоскости ската ставит панель в массив.
    # Зазоры от края и препятствий не проверяются — решение за пользователем.
    class AddPanelTool
      def initialize(group, cfg)
        @group = group
        @cfg = cfg
        @geom = SolarPlanner.array_geom(cfg)
        @panel_u = cfg['panelUMm'].to_f
        @pos = nil
        @ok = false
        refresh
      end

      def refresh
        @cells = SolarPlanner.array_cells(@group, @cfg, @geom)
        tr = @group.transformation
        @w_origin = @geom[:origin].transform(tr)
        @w_u = @geom[:u].transform(tr).normalize
        @w_v = @geom[:v].transform(tr).normalize
        @w_n = @geom[:n].transform(tr).normalize
      end

      def activate
        Sketchup.status_text = 'Добавить панель: щелчок по скату — поставить (зелёный контур), Esc — выйти'
      end

      def deactivate(view)
        view.invalidate
      end

      def onCancel(_reason, _view)
        Sketchup.active_model.select_tool(nil)
      end

      def onMouseMove(_flags, x, y, view)
        pt = Geom.intersect_line_plane(view.pickray(x, y), [@w_origin, @w_n])
        if pt
          d = pt - @w_origin
          u = d.dot(@w_u).to_mm - @panel_u * 0.5
          v = d.dot(@w_v).to_mm - @geom[:proj_v] * 0.5
          @pos = LayoutMath.snap_cell(
            u, v, @cells, @panel_u, @geom[:proj_v],
            @cfg['gapUMm'].to_f, @cfg['rowGapMm'].to_f
          )
          @ok = !LayoutMath.overlaps?(@pos[0], @pos[1], @cells, @panel_u, @geom[:proj_v])
        else
          @pos = nil
        end
        view.invalidate
      end

      def onLButtonDown(_flags, _x, _y, view)
        return unless @pos && @ok

        model = Sketchup.active_model
        model.start_operation('Добавить панель вручную', true)
        begin
          defn = model.definitions[@cfg['panelDef']]
          raise 'не найдено определение панели этого массива' unless defn

          inst = @group.entities.add_instance(defn, SolarPlanner.panel_transform(@geom, @cfg, @pos[0], @pos[1]))
          inst.layer = model.layers.add('PV_Панели')
          SolarPlanner.rebuild_array(model, @group)
          model.commit_operation
        rescue StandardError => e
          model.abort_operation
          UI.messagebox("Не удалось добавить панель:\n#{e.message}")
        end
        refresh
        @ok = false
        SolarPlanner.send_model_bom
        view.invalidate
      end

      def draw(view)
        return unless @pos

        u, v = @pos
        z_low = @geom[:base_z]
        z_high = z_low + @geom[:row_h]
        z_v0, z_v1 = @geom[:tilt_rad] >= 0.0 ? [z_low, z_high] : [z_high, z_low]
        corners = [
          [u, v, z_v0], [u + @panel_u, v, z_v0],
          [u + @panel_u, v + @geom[:proj_v], z_v1], [u, v + @geom[:proj_v], z_v1]
        ]
        pts = corners.map { |a| SolarPlanner.point_on_basis(@w_origin, @w_u, @w_v, @w_n, a[0], a[1], a[2]) }
        view.line_width = 3
        view.drawing_color = @ok ? 'green' : 'red'
        view.draw(GL_LINE_LOOP, pts)
      end

      def getExtents
        bb = Geom::BoundingBox.new
        bb.add(@group.bounds)
        bb
      end
    end

    def self.send_model_bom
      return unless @dialog && @dialog.visible?

      bom = aggregate_model_bom
      js_payload = JSON.generate(bom)
      @dialog.execute_script("window.updateBomFromSketchUp(#{js_payload});")
    end

    # Свободные участки ряда и положения панелей в них.
    # Ряд просматривается вдоль u с шагом SCAN_STEP_MM; в каждой точке проверяются
    # контур грани (с отступом от края) и препятствия (с зазором). Панели ставятся
    # в каждый свободный участок, а не в ячейки одной жёсткой сетки.
    def self.row_panel_runs(model, face, face_tr_inv, origin, u_axis, v_axis, n_axis,
                            face_u_min, face_u_max, v0, v1,
                            panel_u_mm, step_u_mm, grid_origin, margin_mm, obs_clear_mm)
      lo = face_u_min + margin_mm
      hi = face_u_max - margin_mm - panel_u_mm
      return [] if hi < lo

      m = margin_mm * 0.95
      v_contour = LayoutMath.sample_range(v0 - m, v1 + m, 200.0)
      v_obst    = LayoutMath.sample_range(v0 - obs_clear_mm, v1 + obs_clear_mm, 200.0)

      scan_from = face_u_min - obs_clear_mm
      count = ((face_u_max + obs_clear_mm - scan_from) / SCAN_STEP_MM).ceil
      forbidden = []
      (0..count).each do |i|
        x = scan_from + i * SCAN_STEP_MM

        if x > face_u_min + 1.0 && x < face_u_max - 1.0
          outside = v_contour.any? do |sv|
            !point_inside_face?(face, face_tr_inv, origin, u_axis, v_axis, n_axis, x, sv)
          end
          forbidden << [x - panel_u_mm - m - SCAN_STEP_MM, x + m + SCAN_STEP_MM] if outside
        end

        blocked = v_obst.any? do |sv|
          obstacle_at?(model, face, point_on_basis(origin, u_axis, v_axis, n_axis, x, sv, 0.0))
        end
        forbidden << [x - panel_u_mm - obs_clear_mm - SCAN_STEP_MM, x + obs_clear_mm + SCAN_STEP_MM] if blocked
      end

      LayoutMath.pack_runs(lo, hi, forbidden, step_u_mm, grid_origin)
    end

    INSIDE_FLAGS = [
      Sketchup::Face::PointInside,
      Sketchup::Face::PointOnEdge,
      Sketchup::Face::PointOnVertex
    ].freeze

    def self.point_inside_face?(face, face_tr_inv, origin, u_axis, v_axis, n_axis, su, sv)
      world_pt = point_on_basis(origin, u_axis, v_axis, n_axis, su, sv, 0.0)
      local_pt = world_pt.transform(face_tr_inv).project_to_plane(face.plane)
      INSIDE_FLAGS.include?(face.classify_point(local_pt))
    end

    # Препятствие над точкой ската. Луч идёт по вертикали: запретная зона —
    # вертикальная проекция препятствия. Луч по нормали ската (как было) растягивал
    # зону высокой трубы вверх по скату на высота × sin(уклон).
    def self.obstacle_at?(model, face, pt_face)
      ray_start = Geom::Point3d.new(pt_face.x, pt_face.y, pt_face.z + 15.m)
      hit = model.raytest([ray_start, Z_AXIS.reverse], true)
      return false unless hit

      hit_pt, hit_path = hit
      return false if hit_path.last == face

      (hit_pt.z - pt_face.z).to_mm > 35.0
    end

    def self.bracket_positions(u_start, u_end, step_mm)
      return [(u_start + u_end) * 0.5] if u_end <= u_start

      span = u_end - u_start
      count = [(span / step_mm).ceil + 1, 2].max
      actual_step = span / (count - 1).to_f
      (0...count).map { |i| u_start + i * actual_step }
    end

    def self.point_on_basis(origin, u_axis, v_axis, n_axis, u_mm, v_mm, n_mm)
      origin +
        Geom::Vector3d.new(
          u_axis.x * u_mm.mm + v_axis.x * v_mm.mm + n_axis.x * n_mm.mm,
          u_axis.y * u_mm.mm + v_axis.y * v_mm.mm + n_axis.y * n_mm.mm,
          u_axis.z * u_mm.mm + v_axis.z * v_mm.mm + n_axis.z * n_mm.mm
        )
    end

    def self.create_rail_geometry(ents, origin, u_axis, v_axis, n_axis, u0, u1, v0, v1, z0, z1, mat)
      pts = [
        point_on_basis(origin, u_axis, v_axis, n_axis, u0, v0, z0),
        point_on_basis(origin, u_axis, v_axis, n_axis, u1, v0, z0),
        point_on_basis(origin, u_axis, v_axis, n_axis, u1, v1, z0),
        point_on_basis(origin, u_axis, v_axis, n_axis, u0, v1, z0)
      ]
      face = ents.add_face(pts)
      return unless face

      face.material = mat
      face.back_material = mat
      face.reverse! if face.normal.dot(n_axis) < 0
      face.pushpull((z1 - z0).mm)
    end

    PANEL_GEOM_VER = 2

    def self.get_or_create_panel_def(model, model_name, w_mm, h_mm, t_mm)
      def_name = "#{PANEL_DEF_PREFIX}#{model_name.gsub(/[^A-Za-z0-9А-Яа-я_]/, '_')}_#{w_mm.round}x#{h_mm.round}x#{t_mm.round}"
      defn = model.definitions[def_name]
      if defn
        return defn if defn.get_attribute(ATTR_DICT, 'geom_ver').to_i == PANEL_GEOM_VER

        # определение от старой версии: геометрия строится заново, экземпляры в модели обновятся
        defn.entities.clear!
      else
        defn = model.definitions.add(def_name)
      end

      ents = defn.entities
      frame_mat = get_or_create_material(model, 'PV_Frame_Alu', [205, 213, 222])
      cell_mat  = get_or_create_material(model, 'PV_Cells_Dark', [22, 34, 56])

      w = w_mm.mm
      h = h_mm.mm
      t = t_mm.mm

      base = ents.add_face([[0, 0, 0], [w, 0, 0], [w, h, 0], [0, h, 0]])
      base.reverse! if base.normal.z < 0
      base.pushpull(t)

      ents.grep(Sketchup::Face).each { |f| f.material = frame_mat; f.back_material = frame_mat }

      # Поле ячеек — часть верхней грани, а не отдельная грань над ней:
      # две грани с зазором 0,5 мм давали рябь на поверхности (борьба глубин при отрисовке).
      inset = 22.mm
      if w > inset * 2 && h > inset * 2
        ents.add_face([
          [inset, inset, t], [w - inset, inset, t],
          [w - inset, h - inset, t], [inset, h - inset, t]
        ])
        ents.grep(Sketchup::Face).each do |f|
          next unless f.normal.z.abs > 0.99
          next unless f.vertices.all? do |vtx|
            p = vtx.position
            (p.z - t).abs < 0.001 && p.x > inset * 0.5 && p.x < w - inset * 0.5
          end

          f.material = cell_mat
          f.back_material = cell_mat
        end
      end

      defn.set_attribute(ATTR_DICT, 'geom_ver', PANEL_GEOM_VER)
      defn
    end

    # Ячейка раскладки. Для наземной системы — две панели друг над другом по скату,
    # для восток–запад — «домик» из двух панелей; иначе — одна панель.
    def self.get_or_create_cell_def(model, model_name, base_u, base_v, thick, system, angle_deg)
      base = get_or_create_panel_def(model, model_name, base_u, base_v, thick)
      return base unless %w[ground ballast_ew].include?(system)

      name = system == 'ground' ? "#{base.name}_x2" : "#{base.name}_EW#{angle_deg.round}"
      defn = model.definitions[name]
      if defn
        return defn if defn.get_attribute(ATTR_DICT, 'geom_ver').to_i == PANEL_GEOM_VER

        defn.entities.clear!
      else
        defn = model.definitions.add(name)
      end

      ents = defn.entities
      if system == 'ground'
        ents.add_instance(base, Geom::Transformation.new)
        ents.add_instance(base, Geom::Transformation.translation(Geom::Vector3d.new(0, (base_v + GROUND_ROW_GAP_MM).mm, 0)))
      else
        a = angle_deg * Math::PI / 180.0
        dome = 2.0 * base_v * Math.cos(a) + EW_RIDGE_GAP_MM
        ents.add_instance(base, Geom::Transformation.rotation(ORIGIN, X_AXIS, a))
        tr = Geom::Transformation.translation(Geom::Vector3d.new(0, dome.mm, 0)) *
             Geom::Transformation.rotation(ORIGIN, X_AXIS, -a) *
             Geom::Transformation.translation(Geom::Vector3d.new(0, -base_v.mm, 0))
        ents.add_instance(base, tr)
      end
      defn.set_attribute(ATTR_DICT, 'geom_ver', PANEL_GEOM_VER)
      defn
    end

    def self.get_or_create_clamp_def(model, def_name, panel_t_mm, is_mid)
      existing = model.definitions[def_name]
      return existing if existing

      defn = model.definitions.add(def_name)
      ents = defn.entities
      mat = get_or_create_material(model, is_mid ? 'PV_Clamp_Mid' : 'PV_Clamp_End', [51, 65, 85])

      w = (is_mid ? 18.0 : 22.0).mm
      d = 42.0.mm
      h = (panel_t_mm + 6.0).mm

      face = ents.add_face([[-w * 0.5, -d * 0.5, 0], [w * 0.5, -d * 0.5, 0], [w * 0.5, d * 0.5, 0], [-w * 0.5, d * 0.5, 0]])
      face.reverse! if face.normal.z < 0
      face.pushpull(h)
      ents.grep(Sketchup::Face).each { |f| f.material = mat; f.back_material = mat }
      defn
    end

    def self.get_or_create_bracket_def(model, def_name)
      existing = model.definitions[def_name]
      return existing if existing

      defn = model.definitions.add(def_name)
      ents = defn.entities
      mat = get_or_create_material(model, 'PV_Bracket_Steel', [100, 116, 139])

      w = 34.0.mm
      d = 46.0.mm
      h = 100.0.mm

      face = ents.add_face([[-w * 0.5, -d * 0.5, 0], [w * 0.5, -d * 0.5, 0], [w * 0.5, d * 0.5, 0], [-w * 0.5, d * 0.5, 0]])
      face.reverse! if face.normal.z < 0
      face.pushpull(h)
      ents.grep(Sketchup::Face).each { |f| f.material = mat; f.back_material = mat }
      defn
    end

    def self.get_or_create_ballast_def(model, l_mm, w_mm, h_mm)
      def_name = "PV_Балласт_#{l_mm.round}x#{w_mm.round}x#{h_mm.round}"
      existing = model.definitions[def_name]
      return existing if existing

      defn = model.definitions.add(def_name)
      ents = defn.entities
      mat = get_or_create_material(model, 'PV_Concrete_Ballast', [148, 163, 184])

      l = l_mm.mm
      w = w_mm.mm
      h = h_mm.mm

      face = ents.add_face([[-l * 0.5, -w * 0.5, 0], [l * 0.5, -w * 0.5, 0], [l * 0.5, w * 0.5, 0], [-l * 0.5, w * 0.5, 0]])
      face.reverse! if face.normal.z < 0
      face.pushpull(h)
      ents.grep(Sketchup::Face).each { |f| f.material = mat; f.back_material = mat }
      defn
    end

    def self.get_or_create_material(model, name, rgb)
      mat = model.materials[name]
      return mat if mat

      mat = model.materials.add(name)
      mat.color = Sketchup::Color.new(rgb[0], rgb[1], rgb[2])
      mat
    end
  end
end
