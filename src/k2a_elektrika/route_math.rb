# encoding: UTF-8
# Чистая геометрия трасс (без обращения к модели) — тестируется отдельно.

module K2A
  module Elektrika
    module RouteMath
      TOL = 0.5 / 25.4 # 0,5 мм в дюймах

      module_function

      # Убирает дубли, сливает коллинеарные отрезки и «шпильки» (возврат по той же линии).
      # Первая точка не удаляется никогда.
      def clean(pts, tol = TOL)
        res = []
        pts.each do |p|
          q = p
          loop do
            break if res.empty?
            if res.last.distance(q) < tol
              q = nil
              break
            end
            break if res.size < 2
            v1 = res[-1] - res[-2]
            v2 = q - res[-1]
            break unless v1.parallel?(v2)
            res.pop
          end
          res << q if q
        end
        res
      end

      # Ортогональная связка a → b: X, затем Y, затем Z
      def ortho_link(a, b, order = 'x')
        k = a.class
        m1 = order == 'y' ? k.new(a.x, b.y, a.z) : k.new(b.x, a.y, a.z)
        m2 = k.new(b.x, b.y, a.z)
        [a, m1, m2, b]
      end

      # Сдвиг сегмента i на вектор d; концы трассы остаются на месте,
      # соседи достраиваются перемычками, лишние точки сливаются.
      def move_segment(pts, i, d)
        return pts if i.nil? || i < 0 || i >= pts.size - 1
        a = pts[i] + d
        b = pts[i + 1] + d
        clean(pts[0..i] + [a, b] + pts[(i + 1)..-1])
      end

      # Замена начального «отвода» трассы: новый выход p0 и подъём p1,
      # связка по потолку к старой точке pts[1], дальше — старая трасса.
      # Подъём от выхода p0 только до высоты следующей точки трассы (а не до потолка),
      # если трасса правкой опущена на стену. p1 — запасной вариант для пустой трассы.
      def reattach_start(pts, p0, p1)
        return clean([p0, p1]) if pts.size < 2
        nxt = pts[1]
        q = p0.class.new(p0.x, p0.y, nxt.z)
        clean([p0] + ortho_link(q, nxt)[0..-2] + pts[1..-1])
      end

      def reattach_both(pts, a0, a1, b0, b1)
        r = reattach_start(pts, a0, a1)
        reattach_start(r.reverse, b0, b1).reverse
      end

      # Раскладка трасс без перехлёстов.
      # items: [{key:, a:, b:, pa:, pb:, ta:, tb:, level: nil|Integer}]
      #   a/b — ключи механизмов, pa/pb — их точки, ta/tb — касательные (вдоль стены).
      # Уровень: длинные трассы выше (0 — под самым потолком); трассы, не
      # пересекающиеся в плане и без общего механизма, делят уровень.
      # Место подхода к механизму: трассы, пришедшие слева, — в левой части,
      # справа — в правой; выше стоящая ближе к середине.
      # Возврат: {key => {level:, slot_a:, slot_b:}}, слоты в единицах step.
      def layout(items, step)
        span = ->(i) { (i[:pa].x - i[:pb].x).abs + (i[:pa].y - i[:pb].y).abs }
        rect = lambda do |i|
          [[i[:pa].x, i[:pb].x].min, [i[:pa].x, i[:pb].x].max,
           [i[:pa].y, i[:pb].y].min, [i[:pa].y, i[:pb].y].max]
        end
        m = step * 0.5
        conflict = lambda do |i, j|
          return true unless ([i[:a], i[:b]] & [j[:a], j[:b]]).empty?
          r1 = rect.call(i)
          r2 = rect.call(j)
          r1[0] <= r2[1] + m && r2[0] <= r1[1] + m && r1[2] <= r2[3] + m && r2[2] <= r1[3] + m
        end

        levels = {}
        placed = []
        items.select { |i| i[:level] }.each do |i|
          levels[i[:key]] = i[:level]
          placed << i
        end
        items.reject { |i| i[:level] }.sort_by { |i| [-span.call(i), i[:key].to_s] }.each do |i|
          l = 0
          l += 1 while placed.any? { |j| levels[j[:key]] == l && conflict.call(i, j) }
          levels[i[:key]] = l
          placed << i
        end

        res = Hash.new { |h, k| h[k] = { level: levels[k] } }
        ends = Hash.new { |h, k| h[k] = [] }
        items.each do |i|
          ends[i[:a]] << [i, :slot_a, i[:pa], i[:pb], i[:ta]]
          ends[i[:b]] << [i, :slot_b, i[:pb], i[:pa], i[:tb]]
        end
        ends.each_value do |list|
          left = []
          right = []
          list.each do |i, slot, base, other, t|
            dt = (other.x - base.x) * t.x + (other.y - base.y) * t.y
            (dt < 0 ? left : right) << [i, slot, levels[i[:key]], span.call(i)]
          end
          left.sort_by! { |e| [-e[2], -e[3]] }
          right.sort_by! { |e| [e[2], e[3]] }
          order = left + right
          n = order.size
          order.each_with_index do |e, idx|
            res[e[0][:key]][e[1]] = (idx - (n - 1) / 2.0) * step
          end
        end
        items.each { |i| res[i[:key]] }
        res
      end

      def length(pts)
        s = 0.0
        pts.each_cons(2) { |p, q| s += p.distance(q) }
        s
      end
    end
  end
end
