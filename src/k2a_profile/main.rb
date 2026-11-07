# encoding: UTF-8
require 'sketchup.rb'

module K2A
  module Profile
    @w    = 40.mm
    @hgt  = 40.mm
    @mode = 'Стойки'
    @join = 'На ус'
    @caps = 'Да'
    @del  = 'Нет'
    @len  = 'По направляющим'

    VERSION = '1.7.0'.freeze # совпадает с загрузчиком; видна в строке состояния после построения

    Member = Struct.new(:edge, :p1, :p2, :dir, :u, :v, :rank)

    def self.key(pt)
      [pt.x, pt.y, pt.z].map { |c| (c.to_mm * 10).round }
    end

    # Приоритет сквозного элемента в узле; 0 = наклонный
    def self.rank(d)
      if d.parallel?(Z_AXIS)    then @mode == 'Стойки' ? 3 : 1
      elsif d.parallel?(X_AXIS) then @mode == 'Стойки' ? 2 : 3
      elsif d.parallel?(Y_AXIS) then @mode == 'Стойки' ? 1 : 2
      else 0
      end
    end

    # Полуразмер сечения m вдоль направления d
    def self.half(m, d)
      d.dot(m.u).abs * (@w / 2.0) + d.dot(m.v).abs * (@hgt / 2.0)
    end

    def self.vec(d, len)
      Geom::Vector3d.new(d.x * len, d.y * len, d.z * len)
    end

    # Направление наружу через конец элемента m, лежащий в узле p
    def self.out_dir(m, p)
      key(m.p1) == key(p) ? m.dir.reverse : m.dir
    end

    OFFS = lambda do |hw, hh|
      [[hw, hh], [-hw, hh], [-hw, -hh], [hw, -hh]]
    end

    # 4 угла сечения m на плоскости реза
    def self.corners(m, plane)
      OFFS.call(@w / 2.0, @hgt / 2.0).map do |x, y|
        q = m.p1 + Geom::Vector3d.linear_combination(x, m.u, y, m.v)
        r = Geom.intersect_line_plane([q, m.dir], plane)
        return nil unless r
        r
      end
    end

    def self.collinear?(m, p, nodes)
      (nodes[key(p)] - [m]).any? { |o| o.dir.parallel?(m.dir) }
    end

    # Продление/подрезка ортогонального элемента только по ортогональным соседям
    def self.end_ext(m, p, od, nodes)
      others = nodes[key(p)] - [m]
      orth = others.select { |o| o.rank > 0 && !o.dir.parallel?(m.dir) }
      return 0.0 if orth.empty?
      if orth.all? { |o| o.rank < m.rank }
        collinear?(m, p, nodes) ? 0.0 : orth.map { |o| half(o, od) }.max
      else
        -half(orth.max_by(&:rank), od)
      end
    end

    def self.miter?(m, p, nodes)
      others = nodes[key(p)] - [m]
      @join == 'На ус' && others.size == 1 && !others[0].dir.parallel?(m.dir)
    end

    # Помещается ли торец m (рез по грани n элемента o) в пределы этой грани
    def self.fits?(m, p, o, n, plane, nodes)
      cs = corners(m, plane)
      return false unless cs
      w  = n.parallel?(o.u) ? o.v : o.u
      hw = n.parallel?(o.u) ? @hgt / 2.0 : @w / 2.0
      tol = 0.5.mm
      odo = out_dir(o, p)
      lim = collinear?(o, p, nodes) ? nil : end_ext(o, p, odo, nodes)
      cs.all? do |q|
        d = p.vector_to(q)
        next false if d.dot(w).abs > hw + tol
        lim.nil? || d.dot(odo) <= lim + tol
      end
    end

    # Косой рез наклонного m по грани ортогонального соседа
    def self.incl_plane(m, p, nodes)
      od = out_dir(m, p)
      cands = []
      (nodes[key(p)] - [m]).select { |o| o.rank > 0 }.each do |o|
        [o.u, o.u.reverse, o.v, o.v.reverse].each do |n|
          d = n.dot(od)
          next unless d < -0.1
          h = n.parallel?(o.u) ? @w / 2.0 : @hgt / 2.0
          cands << [d, o, n, [p + vec(n, h), n]]
        end
      end
      return [p, od] if cands.empty?
      valid = cands.select { |_d, o, n, pl| fits?(m, p, o, n, pl, nodes) }
      (valid.empty? ? cands : valid).min_by(&:first)[3]
    end

    # Плоскость реза конца m в узле p: [точка, нормаль]
    def self.end_plane(m, p, nodes)
      od = out_dir(m, p)
      others = nodes[key(p)] - [m]

      # Два элемента в узле -> на ус по биссектрисе
      if miter?(m, p, nodes)
        o = others[0]
        n = od.reverse - out_dir(o, p).reverse   # разность направлений "от узла"
        return [p, n.normalize] if n.length > 0
      end

      return incl_plane(m, p, nodes) if m.rank == 0

      ext = end_ext(m, p, od, nodes)
      # Сквозной элемент -> дотянуть до самой дальней точки реза наклонных
      orth = others.select { |o| o.rank > 0 && !o.dir.parallel?(m.dir) }
      if orth.all? { |o| o.rank < m.rank } && !collinear?(m, p, nodes)
        others.select { |o| o.rank == 0 }.each do |i|
          cs = corners(i, incl_plane(i, p, nodes))
          next unless cs
          cs.each { |q| ext = [ext, p.vector_to(q).dot(od)].max }
        end
      end
      [p + vec(od, ext), od]
    end

    def self.orient!(f, outward)
      f.reverse! if f.normal.dot(outward) < 0
    end

    # Плоскость реза как полупространство «внутри элемента»: нормаль наружу, по od
    def self.outward(plane, od)
      pt, n = plane
      n = n.reverse if n.dot(od) < 0
      [pt, n]
    end

    # Плоскости, ограничивающие конец m в узле p.
    # Режим «по направляющим»: дополнительно перпендикуляр к оси в узле — профиль
    # не выходит за конец линии ни одним ребром.
    def self.end_planes(m, p, nodes)
      od = out_dir(m, p)
      list = [outward(end_plane(m, p, nodes), od)]
      if @len == 'По направляющим'
        pt, n = list[0]
        same = n.parallel?(od) && pt.vector_to(p).dot(n).abs < 0.01.mm
        list << [p, od] unless same # свободный конец: рез уже перпендикулярен оси в узле
        # Наклонный (встык и на ус): не выше торца ортогонального соседа, который в узле кончается
        if m.rank == 0
          (nodes[key(p)] - [m]).each do |o|
            next if o.rank == 0 || collinear?(o, p, nodes)
            oo = out_dir(o, p)
            next unless od.dot(oo) > 0.5 # подкос идёт вдоль тела соседа (< 60° к нему); пологий — как ригель
            list << [p, oo]
          end
        end
      end
      list
    end

    # Отсечение плоского выпуклого многоугольника полупространством (x - pt)·n <= 0
    def self.clip(poly, pt, n)
      tol = 0.001.mm
      out = []
      poly.each_with_index do |a, i|
        b = poly[(i + 1) % poly.size]
        da = pt.vector_to(a).dot(n)
        db = pt.vector_to(b).dot(n)
        out << a if da <= tol
        if (da < -tol && db > tol) || (da > tol && db < -tol)
          t = da / (da - db)
          out << Geom::Point3d.linear_combination(1.0 - t, a, t, b)
        end
      end
      dedup(out)
    end

    # Допуск совпадения точек: больше внутреннего допуска SketchUp (0,001" = 0,0254 мм),
    # иначе add_face получает точки, которые SketchUp считает одной («Duplicate points»)
    PT_TOL = 0.05.mm

    # Убрать совпадающие точки и средние точки на одной прямой (порядок обхода сохраняется)
    def self.dedup(pts)
      res = []
      pts.each { |q| res << q unless res.any? { |r| r.distance(q) < PT_TOL } }
      loop do
        break if res.size < 3
        i = (0...res.size).find do |k|
          a = res[k - 1]
          b = res[k]
          c = res[(k + 1) % res.size]
          (a.vector_to(b) * b.vector_to(c)).length < PT_TOL * [a.distance(b), b.distance(c)].max
        end
        break unless i
        res.delete_at(i)
      end
      res
    end

    # Грани профиля: 4 боковые как полосы, обрезанные всеми плоскостями концов,
    # торцы — точки боковых граней, лежащие на плоскости реза.
    def self.solid(m, planes)
      hw = @w / 2.0
      hh = @hgt / 2.0
      offs = [[hw, hh], [-hw, hh], [-hw, -hh], [hw, -hh]]
      len = m.p1.distance(m.p2)
      big = len + 10 * [@w, @hgt].max
      sides = []
      4.times do |i|
        j = (i + 1) % 4
        qi = m.p1 + Geom::Vector3d.linear_combination(offs[i][0], m.u, offs[i][1], m.v)
        qj = m.p1 + Geom::Vector3d.linear_combination(offs[j][0], m.u, offs[j][1], m.v)
        poly = [qi + vec(m.dir, -big), qj + vec(m.dir, -big), qj + vec(m.dir, len + big), qi + vec(m.dir, len + big)]
        planes.each { |pt, n| poly = clip(poly, pt, n) }
        return nil if poly.size < 3
        out = Geom::Vector3d.linear_combination((offs[i][0] + offs[j][0]) / 2.0, m.u, (offs[i][1] + offs[j][1]) / 2.0, m.v)
        sides << [poly, out]
      end
      verts = dedup(sides.flat_map(&:first))
      caps = []
      planes.each do |pt, n|
        on = verts.select { |q| pt.vector_to(q).dot(n).abs < PT_TOL }
        next if on.size < 3
        c = Geom::Point3d.new(on.map(&:x).sum / on.size, on.map(&:y).sum / on.size, on.map(&:z).sum / on.size)
        a = c.vector_to(on[0])
        next if a.length < 0.001.mm
        a.normalize!
        b = n * a
        on = on.sort_by { |q| d = c.vector_to(q); Math.atan2(d.dot(b), d.dot(a)) }
        caps << [on, n]
      end
      t = verts.map { |q| m.p1.vector_to(q).dot(m.dir) }
      return nil if t.max - t.min <= 0.1.mm
      { sides: sides, caps: caps, length: t.max - t.min }
    end

    def self.build(model, m, nodes)
      sol = solid(m, end_planes(m, m.p1, nodes) + end_planes(m, m.p2, nodes))
      return nil unless sol
      g = model.active_entities.add_group
      ents = g.entities
      bad = 0
      faces = sol[:sides]
      faces += sol[:caps] if @caps == 'Да'
      faces.each do |poly, out|
        begin
          f = ents.add_face(dedup(poly))
          orient!(f, out) if f
        rescue ArgumentError => e
          bad += 1 # грань не построилась — остальные строим дальше
          puts "[Профиль] грань пропущена: #{e.message}"
        end
      end
      if ents.grep(Sketchup::Face).empty?
        g.erase!
        return nil
      end
      @bad_faces = (@bad_faces || 0) + bad
      g.name = "Профиль #{@w.to_mm.round}x#{@hgt.to_mm.round} L=#{sol[:length].to_mm.round}"
      g
    end

    def self.run
      model = Sketchup.active_model
      edges = model.selection.grep(Sketchup::Edge)
      if edges.empty?
        UI.messagebox('Выдели рёбра каркаса.')
        return
      end

      prompts = ['Ширина', 'Высота', 'Сквозные в узлах', 'Узел из двух', 'Длина', 'Закрыть торцы', 'Удалить исходные линии']
      lists   = ['', '', 'Стойки|Балки', 'На ус|Встык', 'По направляющим|С выступом', 'Да|Нет', 'Да|Нет']
      res = UI.inputbox(prompts, [@w, @hgt, @mode, @join, @len, @caps, @del], lists, 'Профиль по линиям')
      return unless res
      @w, @hgt, @mode, @join, @len, @caps, @del = res

      members = []
      edges.each do |e|
        p1 = e.start.position
        p2 = e.end.position
        dir = p1.vector_to(p2)
        next if dir.length == 0
        dir.normalize!
        up = dir.parallel?(Z_AXIS) ? X_AXIS : Z_AXIS
        u = (dir * up).normalize
        v = (u * dir).normalize
        members << Member.new(e, p1, p2, dir, u, v, rank(dir))
      end

      nodes = Hash.new { |h, k| h[k] = [] }
      members.each { |m| nodes[key(m.p1)] << m; nodes[key(m.p2)] << m }

      done = 0
      @bad_faces = 0
      model.start_operation('Профиль по линиям', true)
      members.each { |m| done += 1 if build(model, m, nodes) }
      model.active_entities.erase_entities(edges) if @del == 'Да'
      model.commit_operation
      Sketchup.status_text = "Профиль #{VERSION}: #{done} из #{members.size}" +
                             (@bad_faces > 0 ? "; пропущено граней: #{@bad_faces} (подробности — в Ruby-консоли)" : '')
    rescue => err
      model.abort_operation if model
      UI.messagebox("Ошибка: #{err.message}")
    end

    unless file_loaded?(__FILE__)
      c = UI::Command.new('Профиль по линиям') { run }
      icon = File.join(File.dirname(__FILE__), 'icons', 'profile.svg')
      if File.exist?(icon)
        c.small_icon = icon
        c.large_icon = icon
      end
      c.tooltip = 'Профиль по линиям'
      c.status_bar_text = 'Профиль заданного сечения по выделенным рёбрам каркаса'
      UI.menu('Extensions').add_item(c)
      UI.add_context_menu_handler do |menu|
        if Sketchup.active_model.selection.grep(Sketchup::Edge).any?
          menu.add_item(c)
        end
      end
      tb = UI::Toolbar.new('Профиль по линиям')
      tb.add_item(c)
      tb.get_last_state == TB_HIDDEN ? tb.restore : tb.show
      file_loaded(__FILE__)
    end
  end
end
