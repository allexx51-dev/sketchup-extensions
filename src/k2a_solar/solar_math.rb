# frozen_string_literal: true

# Расчётное ядро: положение солнца и зазор между рядами.
# Чистый Ruby, без обращений к SketchUp API — проверяется отдельно от SketchUp.
# Векторы — массивы [x, y, z] в координатах модели.

module K2A
  module SolarMath
    DEG = Math::PI / 180.0
    DECL_WINTER_DEG = -23.44 # склонение солнца 21 декабря
    # Порог освещённости плоскости ската: ниже — момент считается «скат не освещён»
    MIN_INCIDENCE_DEG = 5.0

    # Вектор на солнце в осях Восток–Север–Верх.
    # hour_deg — часовой угол, 15° на час от солнечного полудня (после полудня > 0).
    def self.sun_enu(lat_deg, decl_deg, hour_deg)
      phi = lat_deg * DEG
      dec = decl_deg * DEG
      h   = hour_deg * DEG
      up    = Math.sin(phi) * Math.sin(dec) + Math.cos(phi) * Math.cos(dec) * Math.cos(h)
      south = Math.sin(phi) * Math.cos(dec) * Math.cos(h) - Math.cos(phi) * Math.sin(dec)
      east  = -Math.cos(dec) * Math.sin(h)
      [east, -south, up]
    end

    # Север модели: NorthAngle отсчитывается по часовой стрелке от оси Y (зелёной).
    def self.north_xy(north_angle_deg)
      a = north_angle_deg * DEG
      [Math.sin(a), Math.cos(a)]
    end

    def self.enu_to_model(enu, north_xy)
      nx, ny = north_xy
      ex = ny
      ey = -nx
      [enu[0] * ex + enu[1] * nx, enu[0] * ey + enu[1] * ny, enu[2]]
    end

    def self.dot(a, b)
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    end

    # Зазор между рядами вдoль v, при котором ряд не затеняет соседний
    # во всём расчётном окне.
    #
    # v_axis, n_axis — «вверх по скату» и нормаль ската (единичные, координаты модели)
    # high_mm   — высота поднятого края панели над плоскостью ската
    # proj_mm   — проекция панели на плоскость ската вдоль v
    # tilt_sign — +1: поднят верхний по v край; −1: поднят нижний
    # t_start_h, t_end_h — границы окна, солнечное время, часы
    #
    # Возвращает: gap_mm — требуемый зазор; lit / total — сколько моментов окна
    # скат освещён; worst_h — солнечное время худшего момента.
    def self.row_gap(lat_deg:, north_angle_deg:, v_axis:, n_axis:, high_mm:, proj_mm:,
                     tilt_sign:, t_start_h:, t_end_h:, step_min: 10.0,
                     decl_deg: DECL_WINTER_DEG)
      north = north_xy(north_angle_deg)
      min_sn = Math.sin(MIN_INCIDENCE_DEG * DEG)
      sigma = tilt_sign.negative? ? -1.0 : 1.0

      t0, t1 = [t_start_h, t_end_h].minmax
      count = [((t1 - t0) * 60.0 / step_min).round, 0].max
      times = count.zero? ? [t0] : (0..count).map { |i| t0 + (t1 - t0) * i / count.to_f }

      gap = 0.0
      worst = nil
      lit = 0
      times.each do |t|
        s = enu_to_model(sun_enu(lat_deg, decl_deg, (t - 12.0) * 15.0), north)
        next if s[2] <= 0.0 # солнце под горизонтом

        sn = dot(s, n_axis)
        next if sn < min_sn # скат в собственной тени или свет скользящий

        lit += 1
        # смещение тени поднятого края вдоль «своего» направления, в долях высоты
        k = -sigma * dot(s, v_axis) / sn
        # тень вперёд — на следующий ряд; тень назад дальше собственной проекции — на предыдущий
        need = [high_mm * k, -high_mm * k - proj_mm, 0.0].max
        if need > gap || worst.nil?
          gap = need if need > gap
          worst = t if need >= gap
        end
      end

      { gap_mm: gap, lit: lit, total: times.length, worst_h: worst }
    end
  end
end
