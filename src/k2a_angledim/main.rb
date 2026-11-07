# encoding: UTF-8
require 'sketchup.rb'

module K2A
  module AngleDim
    VERSION = '1.3.0'.freeze
    PREF = 'ak_angledim'.freeze # прежний ключ — чтобы сохранённые настройки не потерялись
    ICON_DIR = File.join(File.dirname(__FILE__), 'icons')

    # Настройки хранятся в настройках SketchUp и переживают перезапуск
    @prec = Sketchup.read_default(PREF, 'prec', 1).to_i
    @sep  = Sketchup.read_default(PREF, 'sep', 'Запятая').to_s
    @tag  = Sketchup.read_default(PREF, 'tag', 'Размеры').to_s
    @arrow = Sketchup.read_default(PREF, 'arrow', 5).to_f # длина стрелки, % радиуса дуги

    class << self
      attr_accessor :prec, :sep, :tag, :arrow
    end

    def self.label(ang)
      s = format("%.#{@prec}f", ang.radians)
      s = s.tr('.', ',') if @sep == 'Запятая'
      s + '°'
    end

    def self.settings
      res = UI.inputbox(['Знаков после запятой', 'Разделитель', 'Тег (пусто - без тега)', 'Стрелка, % радиуса (0 — без стрелок)'],
                        [@prec, @sep, @tag, @arrow], ['0|1|2|3', 'Запятая|Точка', '', ''],
                        "Угловой размер #{VERSION}: настройки")
      return unless res
      @prec = res[0].to_i
      @sep  = res[1]
      @tag  = res[2].to_s.strip
      @arrow = [res[3].to_s.tr(',', '.').to_f, 0].max
      Sketchup.write_default(PREF, 'prec', @prec)
      Sketchup.write_default(PREF, 'sep', @sep)
      Sketchup.write_default(PREF, 'tag', @tag)
      Sketchup.write_default(PREF, 'arrow', @arrow)
    end

    def self.cmd(name, icon, tip, &block)
      c = UI::Command.new(name, &block)
      path = File.join(ICON_DIR, "#{icon}.svg")
      if File.exist?(path)
        c.small_icon = path
        c.large_icon = path
      end
      c.tooltip = name
      c.status_bar_text = tip
      c
    end

    class Tool
      PROMPTS = [
        'Укажи вершину угла',
        'Укажи точку на первой стороне',
        'Укажи точку на второй стороне',
        'Укажи положение дуги или введи радиус'
      ].freeze

      def initialize
        @ip = Sketchup::InputPoint.new
        reset
      end

      def reset
        @step = 0
        @c = @p1 = @p2 = @cur = nil
        @r = nil
        status
      end

      def status
        Sketchup.status_text = PROMPTS[@step]
        Sketchup.vcb_label = 'Радиус'
        Sketchup.vcb_value = ''
      end

      def activate
        reset
      end

      def deactivate(view)
        view.invalidate
      end

      def resume(view)
        status
        view.invalidate
      end

      def onCancel(_reason, view)
        reset
        view.invalidate
      end

      def enableVCB?
        @step == 3
      end

      def vec(v, len)
        Geom::Vector3d.new(v.x * len, v.y * len, v.z * len)
      end

      def rot(v, a)
        v.transform(Geom::Transformation.rotation(ORIGIN, @n, a))
      end

      def arc_pts(r, seg = 24)
        (0..seg).map { |i| @c + vec(rot(@v1, @ang * i / seg), r) }
      end

      def text_pt
        @c + vec(rot(@v1, @ang / 2.0), @r * 1.12)
      end

      def onMouseMove(_flags, x, y, view)
        if @step < 3
          @ip.pick(view, x, y)
          @cur = @ip.position
          view.tooltip = @ip.tooltip
        else
          hit = Geom.intersect_line_plane(view.pickray(x, y), [@c, @n])
          if hit
            @r = @c.distance(hit)
            Sketchup.vcb_value = @r.to_s
          end
        end
        view.invalidate
      end

      def onLButtonDown(_flags, _x, _y, view)
        case @step
        when 0
          @c = @ip.position
          @step = 1
        when 1
          p = @ip.position
          return if p == @c
          @p1 = p
          @step = 2
        when 2
          p = @ip.position
          v1 = @c.vector_to(@p1)
          v2 = @c.vector_to(p)
          if p == @c || v1.parallel?(v2)
            UI.beep
            return
          end
          @p2 = p
          @v1 = v1.normalize
          @v2 = v2.normalize
          @n = (@v1 * @v2).normalize
          @ang = @v1.angle_between(@v2)
          @r = [@c.distance(@p1), @c.distance(@p2)].min * 0.5
          @step = 3
        when 3
          create
          reset
        end
        status
        view.invalidate
      end

      def onUserText(text, view)
        return unless @step == 3
        r = begin
          text.to_l
        rescue ArgumentError
          nil
        end
        unless r && r > 0
          UI.beep
          return
        end
        @r = r
        create
        reset
        view.invalidate
      end

      def create
        model = Sketchup.active_model
        model.start_operation('Угловой размер', true)
        g = model.active_entities.add_group
        e = g.entities

        pts = arc_pts(@r)
        e.add_curve(pts)

        # Стрелки внутрь дуги
        l = @r * AngleDim.arrow / 100.0
        arc_len = @r * @ang
        if l > 0 && arc_len > l * 2.5
          t1 = (@n * @v1).normalize
          s = pts.first
          e.add_line(s, s + vec(t1, l) + vec(@v1, l * 0.3))
          e.add_line(s, s + vec(t1, l) - vec(@v1, l * 0.3))
          t2 = (@v2 * @n).normalize
          f = pts.last
          e.add_line(f, f + vec(t2, l) + vec(@v2, l * 0.3))
          e.add_line(f, f + vec(t2, l) - vec(@v2, l * 0.3))
        end

        # Выносные линии, если дуга дальше указанных точек
        [[@v1, @p1], [@v2, @p2]].each do |v, p|
          d = @c.distance(p)
          e.add_line(@c + vec(v, d), @c + vec(v, @r * 1.06)) if @r > d
        end

        txt = AngleDim.label(@ang)
        t = e.add_text(txt, text_pt)
        t.display_leader = false if t && t.respond_to?(:display_leader=)

        g.name = "Угол #{txt}"
        tag = AngleDim.tag
        unless tag.nil? || tag.empty?
          g.layer = model.layers[tag] || model.layers.add(tag)
        end
        model.commit_operation
      rescue => err
        model.abort_operation
        UI.messagebox("Ошибка: #{err.message}")
      end

      def preview_pts
        pts = []
        pts << @c if @c
        pts << @p1 if @p1
        pts << @p2 if @p2
        pts << @cur if @cur
        pts.concat(arc_pts(@r)) if @step == 3 && @r
        pts
      end

      def getExtents
        bb = Geom::BoundingBox.new
        preview_pts.each { |p| bb.add(p) }
        bb
      end

      def draw(view)
        @ip.draw(view) if @step < 3 && @ip.valid?
        return unless @c
        view.drawing_color = Sketchup::Color.new(0, 0, 255)
        view.line_width = 1
        view.line_stipple = '-'
        a = @p1 || @cur
        view.draw(GL_LINES, [@c, a]) if a && a != @c
        b = @step == 2 ? @cur : @p2
        view.draw(GL_LINES, [@c, b]) if @step >= 2 && b && b != @c
        return unless @step == 3 && @r && @r > 0
        view.line_stipple = ''
        view.line_width = 1
        view.draw(GL_LINE_STRIP, arc_pts(@r))
        view.draw_text(view.screen_coords(text_pt), AngleDim.label(@ang))
      end
    end

    unless file_loaded?(__FILE__)
      c_dim = cmd('Поставить угловой размер', 'angledim', 'Вершина, две стороны, положение дуги') { Sketchup.active_model.select_tool(Tool.new) }
      c_set = cmd('Настройки углового размера', 'settings', 'Знаков после запятой, разделитель, тег') { settings }
      m = UI.menu('Extensions').add_submenu('Угловой размер')
      m.add_item(c_dim)
      m.add_item(c_set)
      tb = UI::Toolbar.new('Угловой размер')
      tb.add_item(c_dim)
      tb.add_item(c_set)
      tb.get_last_state == TB_HIDDEN ? tb.restore : tb.show
      file_loaded(__FILE__)
    end
  end
end
