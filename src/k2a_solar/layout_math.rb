# frozen_string_literal: true

# Упаковка панелей в ряду по свободным участкам. Чистый Ruby, без SketchUp API.

module K2A
  module LayoutMath
    EPS = 1.0e-6

    # Равномерные точки на отрезке [a, b] с шагом не больше max_step (концы включены).
    def self.sample_range(a, b, max_step)
      return [a] if b <= a

      n = [((b - a) / max_step).ceil, 1].max
      (0..n).map { |i| a + (b - a) * i / n.to_f }
    end

    # Положения левых краёв панелей в ряду.
    #
    # lo, hi      — допустимый диапазон левого края панели
    # forbidden   — массив [от, до]: запрещённые (открытые) интервалы левого края
    # step        — шаг панелей (ширина + зазор)
    # grid_origin — фаза общей сетки ската; если сетка даёт столько же панелей,
    #               сколько плотная упаковка, панели остаются на сетке (колонки ровные)
    #
    # Возвращает массив серий; серия — массив левых краёв подряд стоящих панелей.
    def self.pack_runs(lo, hi, forbidden, step, grid_origin)
      runs = []
      return runs if hi < lo - EPS

      emit = lambda do |a, b|
        next if b < a - EPS

        dense = ((b - a + EPS) / step).floor + 1
        k0 = ((a - grid_origin - EPS) / step).ceil
        first = grid_origin + k0 * step
        on_grid = first > b + EPS ? 0 : ((b - first + EPS) / step).floor + 1
        start = if on_grid == dense
                  first
                else
                  a + ((b - a) - (dense - 1) * step) * 0.5
                end
        runs << (0...dense).map { |k| start + k * step }
      end

      cursor = lo
      forbidden.sort_by(&:first).each do |f0, f1|
        next if f1 <= cursor
        break if f0 >= hi

        emit.call(cursor, f0) if f0 >= cursor
        cursor = f1
      end
      emit.call(cursor, hi) if cursor <= hi + EPS
      runs
    end
  end
end

module K2A
  module LayoutMath
    # Панели массива → ряды (по положению поперёк ската), в ряду — по возрастанию u.
    def self.cells_to_rows(cells)
      rows = []
      cells.sort_by { |c| [c[:v0], c[:u0]] }.each do |c|
        if rows.empty? || (c[:v0] - rows.last.first[:v0]).abs > 5.0
          rows << [c]
        else
          rows.last << c
        end
      end
      rows.map { |r| r.sort_by { |c| c[:u0] } }
    end

    # Ряд → серии подряд стоящих панелей (разрыв больше зазора в ряду + 30 мм — новая серия).
    def self.split_series(row, gap_u)
      series = []
      row.each do |c|
        if series.empty? || (c[:u0] - series.last.last[:u1]) > gap_u + 30.0
          series << [c]
        else
          series.last << c
        end
      end
      series
    end

    # Привязка добавляемой вручную панели: к ряду (или шагу рядов), затем к соседу в ряду,
    # иначе к колонке другого ряда. Вне допусков — свободное положение.
    def self.snap_cell(u, v, cells, pu, pv, gap_u, gap_v, tol = 300.0)
      return [u, v] if cells.empty?

      pitch = pv + gap_v
      base = cells.min_by { |c| (c[:v0] - v).abs }[:v0]
      cand = base + ((v - base) / pitch).round * pitch
      v = cand if (v - cand).abs <= [tol, pitch * 0.5].min

      row = cells.select { |c| (c[:v0] - v).abs <= 5.0 }
      best = row.flat_map { |c| [c[:u1] + gap_u, c[:u0] - gap_u - pu] }.min_by { |x| (x - u).abs }
      if best && (best - u).abs <= tol
        u = best
      else
        col = cells.map { |c| c[:u0] }.min_by { |x| (x - u).abs }
        u = col if (col - u).abs <= tol * 0.5
      end
      [u, v]
    end

    def self.overlaps?(u, v, cells, pu, pv)
      cells.any? do |c|
        u < c[:u1] - 1.0 && u + pu > c[:u0] + 1.0 && v < c[:v1] - 1.0 && v + pv > c[:v0] + 1.0
      end
    end
  end
end

module K2A
  module LayoutMath
    # Раскрой профиля по хлыстам. lengths — длины отрезков профиля (мм), stock — длина хлыста.
    # Отрезок длиннее хлыста набирается из целых хлыстов и остатка (стыки — соединителями);
    # остатки укладываются в хлысты «первый подходящий по убыванию», kerf — припуск на рез.
    def self.cut_plan(lengths, stock, kerf = 3.0)
      return { bars: 0, waste_mm: 0.0 } if stock <= 0

      full = 0
      rests = []
      lengths.each do |len|
        n = ((len + EPS) / stock).floor
        full += n
        rest = len - n * stock
        rests << rest if rest > 1.0
      end

      bins = [] # остаток каждого начатого хлыста
      rests.sort.reverse.each do |rest|
        idx = bins.index { |cap| cap >= rest + kerf }
        if idx
          bins[idx] -= rest + kerf
        else
          bins << stock - rest - kerf
        end
      end
      { bars: full + bins.length, waste_mm: bins.sum.round(1) }
    end
  end
end

module K2A
  module LayoutMath
    # Линии треугольников балластной системы для серии панелей (альбомом, три треугольника
    # на панель): оба конца серии, каждый стык панелей и середина каждой панели.
    # Возвращает [[u, :end | :joint | :mid], ...] по возрастанию u.
    def self.ballast_lines(seg)
      lines = [[seg.first[:u0], :end]]
      seg.each_with_index do |cell, i|
        lines << [(cell[:u0] + cell[:u1]) * 0.5, :mid]
        nxt = seg[i + 1]
        lines << [(cell[:u1] + nxt[:u0]) * 0.5, :joint] if nxt
      end
      lines << [seg.last[:u1], :end]
      lines
    end
  end
end

module K2A
  module LayoutMath
    # Стандартные длины профиля RUDNIK (по прайсу), мм
    RAIL_PIECES_MM = [1230.0, 1550.0, 2060.0, 2460.0, 3100.0].freeze

    # Набор стандартных отрезков профиля на линию длиной не меньше required.
    # Минимизируется сумма длин плюс «цена» стыка (соединитель ≈ 180 мм профиля) —
    # так воспроизводятся наборы поставщика для рядов в 1–5 панелей.
    def self.piece_plan(required, pieces = RAIL_PIECES_MM, joint_penalty = 180.0)
      longest = pieces.max
      best = nil
      (0..(required / longest).ceil).each do |count|
        rest = required - count * longest
        combos = if rest <= EPS
                   [[]]
                 else
                   (1..3).flat_map { |k| pieces.repeated_combination(k).select { |c| c.sum >= rest - EPS } }
                 end
        combos.each do |combo|
          plan = [longest] * count + combo
          next if plan.empty?

          cost = plan.sum + joint_penalty * (plan.length - 1)
          best = [cost, plan] if best.nil? || cost < best[0] - EPS
        end
      end
      best[1].sort.reverse
    end

    # Наземный стол RUDNIK: шаг рам не больше 2800 мм, консоль прогона за крайней рамой
    # не больше 825 мм; прогон из модулей 5600 мм и добора.
    # Рамы — наименьшим числом, шаг между ними одинаковый, консоли равны 825 мм. Короткий стол
    # (прогон короче 3300 мм) — две рамы, шаг в половину прогона, консоли по четверти.
    # Добор короче min_piece не ставится: последний модуль и добор делятся на два равных отрезка.
    def self.ground_table(purlin_len, frame_step = 2800.0, max_cantilever = 825.0, module_len = 5600.0,
                          min_piece = 1000.0)
      frames = [((purlin_len - 2.0 * max_cantilever) / frame_step - EPS).ceil + 1, 2].max
      spacing = (purlin_len - 2.0 * max_cantilever) / (frames - 1) # не больше frame_step по выбору frames
      spacing = [[spacing, purlin_len * 0.5].max, frame_step].min if frames == 2
      cantilever = (purlin_len - spacing * (frames - 1)) * 0.5

      full = ((purlin_len + EPS) / module_len).floor
      rest = purlin_len - full * module_len
      pieces = [module_len] * full
      if rest > 1.0 && rest < min_piece && full.positive?
        pieces.pop
        half = ((module_len + rest) * 0.5).round
        pieces += [half, (module_len + rest).round - half]
      elsif rest > 1.0
        pieces << rest.round
      end
      { frames: frames, spacing: spacing, cantilever: cantilever, pieces: pieces }
    end
  end
end

module K2A
  module LayoutMath
    # Положения рядов поперёк ската: ряды собраны в полосы по per_strip рядов с зазором gap,
    # между полосами — проход aisle. При per_strip = 1 проход равен зазору.
    def self.row_offsets(avail, proj, gap, per_strip = 1, aisle = nil)
      per_strip = [per_strip.to_i, 1].max
      aisle = gap if aisle.nil? || per_strip == 1
      offsets = []
      off = 0.0
      while off + proj <= avail + EPS && offsets.length < 5000
        offsets << off
        off += proj + ((offsets.length % per_strip).zero? ? aisle : gap)
      end
      offsets
    end

    # Стопки панелей для профиля поперёк ряда: колонка (одинаковое u0), в ней панели подряд
    # по v с разрывом не больше max_gap.
    def self.cells_to_stacks(cells, max_gap)
      cols = []
      cells.sort_by { |c| [c[:u0], c[:v0]] }.each do |c|
        if cols.empty? || (c[:u0] - cols.last.first[:u0]).abs > 5.0
          cols << [c]
        else
          cols.last << c
        end
      end
      cols.flat_map do |col|
        stacks = []
        col.sort_by { |c| c[:v0] }.each do |c|
          if stacks.empty? || c[:v0] - stacks.last.last[:v1] > max_gap
            stacks << [c]
          else
            stacks.last << c
          end
        end
        stacks
      end
    end
  end
end
