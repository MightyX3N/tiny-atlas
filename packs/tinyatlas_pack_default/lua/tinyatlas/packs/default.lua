-- Tiny Atlas asset pack. Format: docs/FORMATS.md
return {
  id = "default",
  name = "Default",
  author = "Tiny Atlas",
  version = "1.0.0",
  license = "Ships with the game only. Art: Antahonist terrain tiles (free, no resale), Pixel Art Isometric Tree pack and Bush pack (same creator), VOiD1 Gaming Low-Poly Bike Models.",
  credits = { "Terrain & nature: Antahonist (antahonist.itch.io)", "Trees: Pixel Art Isometric Tree pack", "Bushes, rocks, grass: Pixel Art Isometric Bush / Rock / Grass packs (same creator as the trees)", "Water: baked with WOWe Generator by Yavuz (MIT)", "Bike: VOiD1 Gaming" },
  local_only = false,
  tile_metres = 3.3,
  edge_darken = 0.28,
  ground = {
    urban = { "ground/urban_1.png" },
    grass = { "ground/grass_1.png", "ground/grass_2.png", "ground/grass_3.png", "ground/grass_4.png" },
    scrub = { "ground/scrub_1.png", "ground/scrub_2.png", "ground/scrub_3.png", "ground/scrub_4.png" },
    water = { "ground/water_1.png" },
    asphalt = { "ground/asphalt_1.png" },
    paving = { "ground/paving_1.png" },
    cobble = { "ground/cobble_1.png" },
    gravel = { "ground/gravel_1.png" },
    sand = { "ground/sand_1.png", "ground/sand_2.png", "ground/sand_3.png", "ground/sand_4.png" },
    cycleway = { "ground/cycleway_1.png" },
    dirt = { "ground/dirt_1.png", "ground/dirt_2.png", "ground/dirt_3.png", "ground/dirt_4.png" },
    rail = { "ground/rail_1.png" },
    pitch = { "ground/pitch_1.png", "ground/pitch_2.png", "ground/pitch_3.png", "ground/pitch_4.png" },
    farmland = { "ground/farmland_1.png" },
    forest_floor = { "ground/forest_floor_1.png", "ground/forest_floor_2.png", "ground/forest_floor_3.png", "ground/forest_floor_4.png" },
    meadow = { "ground/meadow_1.png", "ground/meadow_2.png", "ground/meadow_3.png", "ground/meadow_4.png" },
    rock = { "ground/rock_1.png" },
    snow = { "ground/snow_1.png", "ground/snow_2.png", "ground/snow_3.png", "ground/snow_4.png" },
    wetland = { "ground/wetland_1.png", "ground/wetland_2.png", "ground/wetland_3.png", "ground/wetland_4.png" },
    orchard = { "ground/orchard_1.png", "ground/orchard_2.png", "ground/orchard_3.png", "ground/orchard_4.png" },
    rural = { "ground/rural_1.png", "ground/rural_2.png", "ground/rural_3.png", "ground/rural_4.png" },
    parking = { "ground/parking_1.png" },
    dry_grass = { "ground/dry_grass_1.png", "ground/dry_grass_2.png", "ground/dry_grass_3.png", "ground/dry_grass_4.png" },
  },
  ground_priority = {
    water = 1,
    grass = 2,
    scrub = 2,
    forest_floor = 2,
    meadow = 2,
    farmland = 2,
    rural = 2,
    orchard = 2,
    wetland = 2,
    dry_grass = 2,
    sand = 3,
    dirt = 4,
    gravel = 4,
    paving = 5,
    cobble = 5,
    asphalt = 6,
    parking = 6,
    rail = 6,
    cycleway = 7,
  },
  seasons = {
    winter = {
      ground = {
        grass = { "ground/grass_winter_1.png", "ground/grass_winter_2.png", "ground/grass_winter_3.png", "ground/grass_winter_4.png" },
        rural = { "ground/rural_winter_1.png", "ground/rural_winter_2.png", "ground/rural_winter_3.png", "ground/rural_winter_4.png" },
        meadow = { "ground/meadow_winter_1.png", "ground/meadow_winter_2.png", "ground/meadow_winter_3.png", "ground/meadow_winter_4.png" },
        forest_floor = { "ground/forest_floor_winter_1.png", "ground/forest_floor_winter_2.png", "ground/forest_floor_winter_3.png", "ground/forest_floor_winter_4.png" },
        farmland = { "ground/farmland_winter_1.png", "ground/farmland_winter_2.png", "ground/farmland_winter_3.png", "ground/farmland_winter_4.png" },
      },
      trees = {
        broadleaf = {
          sprites = { "trees/bare_1.png", "trees/bare_2.png", "trees/bare_3.png", "trees/bare_4.png", "trees/bare_5.png", "trees/bare_6.png" },
        },
        shrub = {
          sprites = { "props/bushes/frost_12.png", "props/bushes/frost_13.png", "props/bushes/frost_14.png", "props/bushes/frost_15.png" },
        },
      },
      props = {
        scrub = {
          {
            sprites = { "props/bushes/frost_12.png", "props/bushes/frost_13.png", "props/bushes/frost_14.png", "props/bushes/frost_15.png" },
            density = 0.8,
            size = 1.3,
          },
        },
        forest_floor = {
          {
            sprites = { "props/log_winter_0.png", "props/log_winter_1.png", "props/log_winter_2.png", "props/log_winter_3.png" },
            density = 0.08,
            size = 1.2,
          },
          {
            sprites = { "props/bushes/frost_12.png", "props/bushes/frost_13.png", "props/bushes/frost_14.png", "props/bushes/frost_15.png" },
            density = 0.3,
            size = 1.2,
          },
        },
        dry_grass = {
          {
            sprites = { "props/bushes/frost_12.png", "props/bushes/frost_13.png", "props/bushes/frost_14.png", "props/bushes/frost_15.png" },
            density = 0.2,
            size = 1.0,
          },
          {
            sprites = { "props/grass/frost_20_7.png", "props/grass/frost_20_14.png", "props/grass/frost_20_21.png", "props/grass/frost_20_28.png", "props/grass/frost_20_35.png", "props/grass/frost_20_42.png", "props/grass/frost_20_49.png", "props/grass/frost_20_56.png", "props/grass/frost_20_63.png", "props/grass/frost_20_70.png", "props/grass/frost_20_77.png" },
            density = 0.6,
            size = 0.45,
          },
        },
        grass = {
          {
            sprites = { "props/grass/frost_20_7.png", "props/grass/frost_20_14.png", "props/grass/frost_20_21.png", "props/grass/frost_20_28.png", "props/grass/frost_20_35.png", "props/grass/frost_20_42.png", "props/grass/frost_20_49.png", "props/grass/frost_20_56.png", "props/grass/frost_20_63.png", "props/grass/frost_20_70.png", "props/grass/frost_20_77.png" },
            density = 0.4,
            size = 0.4,
          },
        },
        meadow = {
          {
            sprites = { "props/grass/frost_20_7.png", "props/grass/frost_20_14.png", "props/grass/frost_20_21.png", "props/grass/frost_20_28.png", "props/grass/frost_20_35.png", "props/grass/frost_20_42.png", "props/grass/frost_20_49.png", "props/grass/frost_20_56.png", "props/grass/frost_20_63.png", "props/grass/frost_20_70.png", "props/grass/frost_20_77.png" },
            density = 0.8,
            size = 0.45,
          },
        },
        rural = {
          {
            sprites = { "props/grass/frost_20_7.png", "props/grass/frost_20_14.png", "props/grass/frost_20_21.png", "props/grass/frost_20_28.png", "props/grass/frost_20_35.png", "props/grass/frost_20_42.png", "props/grass/frost_20_49.png", "props/grass/frost_20_56.png", "props/grass/frost_20_63.png", "props/grass/frost_20_70.png", "props/grass/frost_20_77.png" },
            density = 0.3,
            size = 0.45,
          },
        },
        rock = {
          {
            sprites = { "props/rocks/snowy_20.png", "props/rocks/snowy_21.png", "props/rocks/snowy_22.png", "props/rocks/snowy_23.png", "props/rocks/snowy_24.png", "props/rocks/snowy_25.png", "props/rocks/snowy_26.png", "props/rocks/snowy_27.png", "props/rocks/snowy_28.png", "props/rocks/snowy_29.png", "props/rocks/snowy_30.png", "props/rocks/snowy_32.png", "props/rocks/snowy_36.png", "props/rocks/snowy_38.png", "props/rocks/snowy_39.png", "props/rocks/snowy_40.png", "props/rocks/snowy_41.png", "props/rocks/snowy_42.png", "props/rocks/snowy_43.png", "props/rocks/snowy_47.png", "props/rocks/snowy_48.png", "props/rocks/snowy_49.png" },
            density = 0.25,
            size = 2.4,
          },
          {
            sprites = { "props/rocks/snowy_10.png", "props/rocks/snowy_11.png", "props/rocks/snowy_12.png", "props/rocks/snowy_13.png", "props/rocks/snowy_14.png", "props/rocks/snowy_15.png", "props/rocks/snowy_16.png", "props/rocks/snowy_17.png", "props/rocks/snowy_18.png", "props/rocks/snowy_19.png" },
            density = 0.35,
            size = 1.2,
          },
          {
            sprites = { "props/rocks/snowy_0.png", "props/rocks/snowy_1.png", "props/rocks/snowy_2.png", "props/rocks/snowy_3.png", "props/rocks/snowy_4.png", "props/rocks/snowy_5.png", "props/rocks/snowy_6.png", "props/rocks/snowy_7.png", "props/rocks/snowy_8.png", "props/rocks/snowy_9.png" },
            density = 0.6,
            size = 0.6,
          },
        },
      },
    },
    autumn = {
      trees = {
        broadleaf = {
          sprites = { "trees/autumn_1.png", "trees/autumn_2.png", "trees/autumn_3.png", "trees/autumn_4.png", "trees/autumn_5.png", "trees/autumn_6.png", "trees/autumn_7.png", "trees/autumn_8.png", "trees/autumn_9.png", "trees/autumn_10.png", "trees/autumn_11.png", "trees/autumn_12.png", "trees/autumn_13.png", "trees/autumn_14.png" },
        },
        shrub = {
          sprites = { "props/bushes/orange_16.png", "props/bushes/orange_17.png", "props/bushes/orange_18.png", "props/bushes/orange_19.png", "props/bushes/yellow_20.png", "props/bushes/yellow_21.png", "props/bushes/yellow_22.png", "props/bushes/yellow_23.png", "props/bushes/amber_28.png", "props/bushes/amber_29.png", "props/bushes/amber_30.png", "props/bushes/amber_31.png", "props/bushes/red_32.png", "props/bushes/red_33.png" },
        },
      },
      props = {
        scrub = {
          {
            sprites = { "props/bushes/orange_16.png", "props/bushes/orange_17.png", "props/bushes/orange_18.png", "props/bushes/orange_19.png", "props/bushes/yellow_20.png", "props/bushes/yellow_21.png", "props/bushes/yellow_22.png", "props/bushes/yellow_23.png", "props/bushes/amber_28.png", "props/bushes/amber_29.png", "props/bushes/amber_30.png", "props/bushes/amber_31.png", "props/bushes/red_32.png", "props/bushes/red_33.png" },
            density = 0.8,
            size = 1.4,
          },
        },
        forest_floor = {
          {
            sprites = { "props/log_autumn_0.png", "props/log_autumn_1.png", "props/log_autumn_2.png", "props/log_autumn_3.png" },
            density = 0.08,
            size = 1.2,
          },
          {
            sprites = { "props/stump_autumn_0.png", "props/stump_autumn_1.png", "props/stump_autumn_2.png", "props/stump_autumn_3.png" },
            density = 0.1,
            size = 0.8,
          },
          {
            sprites = { "props/bushes/orange_16.png", "props/bushes/orange_17.png", "props/bushes/orange_18.png", "props/bushes/orange_19.png", "props/bushes/yellow_20.png", "props/bushes/yellow_21.png", "props/bushes/yellow_22.png", "props/bushes/yellow_23.png", "props/bushes/amber_28.png", "props/bushes/amber_29.png", "props/bushes/amber_30.png", "props/bushes/amber_31.png", "props/bushes/red_32.png", "props/bushes/red_33.png" },
            density = 0.35,
            size = 1.3,
          },
        },
        dry_grass = {
          {
            sprites = { "props/bushes/amber_28.png", "props/bushes/amber_29.png", "props/bushes/amber_30.png", "props/bushes/amber_31.png", "props/bushes/orange_16.png", "props/bushes/orange_17.png", "props/bushes/orange_18.png", "props/bushes/orange_19.png" },
            density = 0.25,
            size = 1.1,
          },
          {
            sprites = { "props/grass/yellow_21_0.png", "props/grass/yellow_21_7.png", "props/grass/yellow_21_14.png", "props/grass/yellow_21_21.png", "props/grass/yellow_21_28.png", "props/grass/yellow_21_35.png", "props/grass/yellow_21_42.png", "props/grass/yellow_21_49.png", "props/grass/yellow_21_56.png", "props/grass/yellow_21_63.png", "props/grass/yellow_21_70.png", "props/grass/yellow_21_77.png", "props/grass/yellow_23_0.png", "props/grass/yellow_23_7.png", "props/grass/yellow_23_14.png", "props/grass/yellow_23_21.png", "props/grass/yellow_23_28.png", "props/grass/yellow_23_35.png", "props/grass/yellow_23_42.png", "props/grass/yellow_23_49.png", "props/grass/yellow_23_56.png", "props/grass/yellow_23_63.png", "props/grass/yellow_23_70.png", "props/grass/yellow_23_77.png", "props/grass/red_16_0.png", "props/grass/red_16_7.png", "props/grass/red_16_14.png", "props/grass/red_16_21.png", "props/grass/red_16_28.png", "props/grass/red_16_35.png", "props/grass/red_16_42.png", "props/grass/red_16_49.png", "props/grass/red_16_56.png", "props/grass/red_16_63.png", "props/grass/red_16_70.png", "props/grass/red_16_77.png", "props/grass/red_17_0.png", "props/grass/red_17_7.png", "props/grass/red_17_14.png", "props/grass/red_17_21.png", "props/grass/red_17_28.png", "props/grass/red_17_35.png", "props/grass/red_17_42.png", "props/grass/red_17_49.png", "props/grass/red_17_56.png", "props/grass/red_17_63.png", "props/grass/red_17_70.png", "props/grass/red_17_77.png" },
            density = 1.0,
            size = 0.5,
          },
        },
        meadow = {
          {
            sprites = { "props/grass/yellow_21_0.png", "props/grass/yellow_21_7.png", "props/grass/yellow_21_14.png", "props/grass/yellow_21_21.png", "props/grass/yellow_21_28.png", "props/grass/yellow_21_35.png", "props/grass/yellow_21_42.png", "props/grass/yellow_21_49.png", "props/grass/yellow_21_56.png", "props/grass/yellow_21_63.png", "props/grass/yellow_21_70.png", "props/grass/yellow_21_77.png", "props/grass/yellow_23_0.png", "props/grass/yellow_23_7.png", "props/grass/yellow_23_14.png", "props/grass/yellow_23_21.png", "props/grass/yellow_23_28.png", "props/grass/yellow_23_35.png", "props/grass/yellow_23_42.png", "props/grass/yellow_23_49.png", "props/grass/yellow_23_56.png", "props/grass/yellow_23_63.png", "props/grass/yellow_23_70.png", "props/grass/yellow_23_77.png", "props/grass/green_7_0.png", "props/grass/green_7_7.png", "props/grass/green_7_14.png", "props/grass/green_7_21.png", "props/grass/green_7_28.png", "props/grass/green_7_35.png", "props/grass/green_7_42.png", "props/grass/green_7_49.png", "props/grass/green_7_56.png", "props/grass/green_7_63.png", "props/grass/green_7_70.png", "props/grass/green_7_77.png", "props/grass/green_8_0.png", "props/grass/green_8_7.png", "props/grass/green_8_14.png", "props/grass/green_8_21.png", "props/grass/green_8_28.png", "props/grass/green_8_35.png", "props/grass/green_8_42.png", "props/grass/green_8_49.png", "props/grass/green_8_56.png", "props/grass/green_8_63.png", "props/grass/green_8_70.png", "props/grass/green_8_77.png", "props/grass/green_10_0.png", "props/grass/green_10_7.png", "props/grass/green_10_14.png", "props/grass/green_10_21.png", "props/grass/green_10_28.png", "props/grass/green_10_35.png", "props/grass/green_10_42.png", "props/grass/green_10_49.png", "props/grass/green_10_56.png", "props/grass/green_10_63.png", "props/grass/green_10_70.png", "props/grass/green_10_77.png", "props/grass/green_3_0.png", "props/grass/green_3_7.png", "props/grass/green_3_14.png", "props/grass/green_3_21.png", "props/grass/green_3_28.png", "props/grass/green_3_35.png", "props/grass/green_3_42.png", "props/grass/green_3_49.png", "props/grass/green_3_56.png", "props/grass/green_3_63.png", "props/grass/green_3_70.png", "props/grass/green_3_77.png", "props/grass/red_16_0.png", "props/grass/red_16_7.png", "props/grass/red_16_14.png", "props/grass/red_16_21.png", "props/grass/red_16_28.png", "props/grass/red_16_35.png", "props/grass/red_16_42.png", "props/grass/red_16_49.png", "props/grass/red_16_56.png", "props/grass/red_16_63.png", "props/grass/red_16_70.png", "props/grass/red_16_77.png", "props/grass/red_17_0.png", "props/grass/red_17_7.png", "props/grass/red_17_14.png", "props/grass/red_17_21.png", "props/grass/red_17_28.png", "props/grass/red_17_35.png", "props/grass/red_17_42.png", "props/grass/red_17_49.png", "props/grass/red_17_56.png", "props/grass/red_17_63.png", "props/grass/red_17_70.png", "props/grass/red_17_77.png" },
            density = 1.4,
            size = 0.55,
          },
        },
        grass = {
          {
            sprites = { "props/grass/green_7_0.png", "props/grass/green_7_7.png", "props/grass/green_7_14.png", "props/grass/green_7_21.png", "props/grass/green_7_28.png", "props/grass/green_7_35.png", "props/grass/green_7_42.png", "props/grass/green_7_49.png", "props/grass/green_7_56.png", "props/grass/green_7_63.png", "props/grass/green_7_70.png", "props/grass/green_7_77.png", "props/grass/green_8_0.png", "props/grass/green_8_7.png", "props/grass/green_8_14.png", "props/grass/green_8_21.png", "props/grass/green_8_28.png", "props/grass/green_8_35.png", "props/grass/green_8_42.png", "props/grass/green_8_49.png", "props/grass/green_8_56.png", "props/grass/green_8_63.png", "props/grass/green_8_70.png", "props/grass/green_8_77.png", "props/grass/green_10_0.png", "props/grass/green_10_7.png", "props/grass/green_10_14.png", "props/grass/green_10_21.png", "props/grass/green_10_28.png", "props/grass/green_10_35.png", "props/grass/green_10_42.png", "props/grass/green_10_49.png", "props/grass/green_10_56.png", "props/grass/green_10_63.png", "props/grass/green_10_70.png", "props/grass/green_10_77.png", "props/grass/green_3_0.png", "props/grass/green_3_7.png", "props/grass/green_3_14.png", "props/grass/green_3_21.png", "props/grass/green_3_28.png", "props/grass/green_3_35.png", "props/grass/green_3_42.png", "props/grass/green_3_49.png", "props/grass/green_3_56.png", "props/grass/green_3_63.png", "props/grass/green_3_70.png", "props/grass/green_3_77.png", "props/grass/yellow_21_0.png", "props/grass/yellow_21_7.png", "props/grass/yellow_21_14.png", "props/grass/yellow_21_21.png", "props/grass/yellow_21_28.png", "props/grass/yellow_21_35.png", "props/grass/yellow_21_42.png", "props/grass/yellow_21_49.png", "props/grass/yellow_21_56.png", "props/grass/yellow_21_63.png", "props/grass/yellow_21_70.png", "props/grass/yellow_21_77.png", "props/grass/yellow_23_0.png", "props/grass/yellow_23_7.png", "props/grass/yellow_23_14.png", "props/grass/yellow_23_21.png", "props/grass/yellow_23_28.png", "props/grass/yellow_23_35.png", "props/grass/yellow_23_42.png", "props/grass/yellow_23_49.png", "props/grass/yellow_23_56.png", "props/grass/yellow_23_63.png", "props/grass/yellow_23_70.png", "props/grass/yellow_23_77.png" },
            density = 0.8,
            size = 0.45,
          },
        },
      },
    },
  },
  water = {
    texture = "water/still_0.png",
    opacity = 0.86,
    bed_tint = { 0.55, 0.6, 0.62 },
    still = {
      sheet = "water/still.png",
      frames = 16,
      ms = 90,
      tile_metres = 11.2,
    },
    river = {
      sheet = "water/river.png",
      frames = 16,
      ms = 90,
      tile_metres = 11.2,
      flows = "down",
    },
  },
  wall = {
    texture = "ground/cobble_1.png",
    tint = { 0.95, 0.9, 0.85 },
  },
  sky = {
    top = "#6fa6dc",
    horizon = "#c8dbe8",
    haze = "#c8dbe8",
    fog_near = 300,
    fog_far = 7000,
  },
  sun = {
    colour = "#fff1d6",
    strength = 2.4,
    ambient = "#dfeeff",
    ground = "#6b6050",
  },
  trees = {
    broadleaf = {
      sprites = { "trees/broadleaf_1.png", "trees/broadleaf_2.png", "trees/broadleaf_3.png", "trees/broadleaf_4.png", "trees/broadleaf_5.png", "trees/broadleaf_6.png", "trees/broadleaf_7.png", "trees/broadleaf_8.png", "trees/broadleaf_9.png", "trees/broadleaf_10.png" },
      height = { 10, 16 },
    },
    conifer = {
      sprites = { "trees/conifer_1.png", "trees/conifer_2.png", "trees/conifer_3.png", "trees/conifer_4.png" },
      height = { 12, 22 },
    },
    orchard = {
      sprites = { "trees/broadleaf_1.png", "trees/broadleaf_2.png", "trees/broadleaf_3.png", "trees/broadleaf_4.png", "trees/broadleaf_5.png", "trees/broadleaf_6.png", "trees/broadleaf_7.png", "trees/broadleaf_8.png", "trees/broadleaf_9.png", "trees/broadleaf_10.png" },
      height = { 4, 6 },
    },
    shrub = {
      sprites = { "props/bushes/green_0.png", "props/bushes/green_1.png", "props/bushes/green_2.png", "props/bushes/green_3.png", "props/bushes/olive_4.png", "props/bushes/olive_5.png", "props/bushes/olive_6.png", "props/bushes/olive_7.png", "props/bushes/mint_24.png", "props/bushes/mint_25.png", "props/bushes/mint_26.png", "props/bushes/mint_27.png", "props/bushes/pink_8.png", "props/bushes/pink_9.png" },
      height = { 1.2, 2.4 },
    },
  },
  props = {
    grass = {
      {
        sprites = { "props/flowers_summer_0.png", "props/flowers_summer_1.png", "props/flowers_summer_2.png", "props/flowers_summer_3.png" },
        density = 0.25,
        size = 0.6,
      },
      {
        sprites = { "props/grass/green_7_0.png", "props/grass/green_7_7.png", "props/grass/green_7_14.png", "props/grass/green_7_21.png", "props/grass/green_7_28.png", "props/grass/green_7_35.png", "props/grass/green_7_42.png", "props/grass/green_7_49.png", "props/grass/green_7_56.png", "props/grass/green_7_63.png", "props/grass/green_7_70.png", "props/grass/green_7_77.png", "props/grass/green_8_0.png", "props/grass/green_8_7.png", "props/grass/green_8_14.png", "props/grass/green_8_21.png", "props/grass/green_8_28.png", "props/grass/green_8_35.png", "props/grass/green_8_42.png", "props/grass/green_8_49.png", "props/grass/green_8_56.png", "props/grass/green_8_63.png", "props/grass/green_8_70.png", "props/grass/green_8_77.png", "props/grass/green_10_0.png", "props/grass/green_10_7.png", "props/grass/green_10_14.png", "props/grass/green_10_21.png", "props/grass/green_10_28.png", "props/grass/green_10_35.png", "props/grass/green_10_42.png", "props/grass/green_10_49.png", "props/grass/green_10_56.png", "props/grass/green_10_63.png", "props/grass/green_10_70.png", "props/grass/green_10_77.png", "props/grass/green_3_0.png", "props/grass/green_3_7.png", "props/grass/green_3_14.png", "props/grass/green_3_21.png", "props/grass/green_3_28.png", "props/grass/green_3_35.png", "props/grass/green_3_42.png", "props/grass/green_3_49.png", "props/grass/green_3_56.png", "props/grass/green_3_63.png", "props/grass/green_3_70.png", "props/grass/green_3_77.png" },
        density = 0.9,
        size = 0.45,
      },
    },
    meadow = {
      {
        sprites = { "props/flowers_summer_0.png", "props/flowers_summer_1.png", "props/flowers_summer_2.png", "props/flowers_summer_3.png" },
        density = 0.8,
        size = 0.6,
      },
      {
        sprites = { "props/grass/green_7_0.png", "props/grass/green_7_7.png", "props/grass/green_7_14.png", "props/grass/green_7_21.png", "props/grass/green_7_28.png", "props/grass/green_7_35.png", "props/grass/green_7_42.png", "props/grass/green_7_49.png", "props/grass/green_7_56.png", "props/grass/green_7_63.png", "props/grass/green_7_70.png", "props/grass/green_7_77.png", "props/grass/green_8_0.png", "props/grass/green_8_7.png", "props/grass/green_8_14.png", "props/grass/green_8_21.png", "props/grass/green_8_28.png", "props/grass/green_8_35.png", "props/grass/green_8_42.png", "props/grass/green_8_49.png", "props/grass/green_8_56.png", "props/grass/green_8_63.png", "props/grass/green_8_70.png", "props/grass/green_8_77.png", "props/grass/green_10_0.png", "props/grass/green_10_7.png", "props/grass/green_10_14.png", "props/grass/green_10_21.png", "props/grass/green_10_28.png", "props/grass/green_10_35.png", "props/grass/green_10_42.png", "props/grass/green_10_49.png", "props/grass/green_10_56.png", "props/grass/green_10_63.png", "props/grass/green_10_70.png", "props/grass/green_10_77.png", "props/grass/green_3_0.png", "props/grass/green_3_7.png", "props/grass/green_3_14.png", "props/grass/green_3_21.png", "props/grass/green_3_28.png", "props/grass/green_3_35.png", "props/grass/green_3_42.png", "props/grass/green_3_49.png", "props/grass/green_3_56.png", "props/grass/green_3_63.png", "props/grass/green_3_70.png", "props/grass/green_3_77.png" },
        density = 1.6,
        size = 0.55,
      },
    },
    rural = {
      {
        sprites = { "props/grass/green_7_0.png", "props/grass/green_7_7.png", "props/grass/green_7_14.png", "props/grass/green_7_21.png", "props/grass/green_7_28.png", "props/grass/green_7_35.png", "props/grass/green_7_42.png", "props/grass/green_7_49.png", "props/grass/green_7_56.png", "props/grass/green_7_63.png", "props/grass/green_7_70.png", "props/grass/green_7_77.png", "props/grass/green_8_0.png", "props/grass/green_8_7.png", "props/grass/green_8_14.png", "props/grass/green_8_21.png", "props/grass/green_8_28.png", "props/grass/green_8_35.png", "props/grass/green_8_42.png", "props/grass/green_8_49.png", "props/grass/green_8_56.png", "props/grass/green_8_63.png", "props/grass/green_8_70.png", "props/grass/green_8_77.png", "props/grass/green_10_0.png", "props/grass/green_10_7.png", "props/grass/green_10_14.png", "props/grass/green_10_21.png", "props/grass/green_10_28.png", "props/grass/green_10_35.png", "props/grass/green_10_42.png", "props/grass/green_10_49.png", "props/grass/green_10_56.png", "props/grass/green_10_63.png", "props/grass/green_10_70.png", "props/grass/green_10_77.png", "props/grass/green_3_0.png", "props/grass/green_3_7.png", "props/grass/green_3_14.png", "props/grass/green_3_21.png", "props/grass/green_3_28.png", "props/grass/green_3_35.png", "props/grass/green_3_42.png", "props/grass/green_3_49.png", "props/grass/green_3_56.png", "props/grass/green_3_63.png", "props/grass/green_3_70.png", "props/grass/green_3_77.png" },
        density = 0.5,
        size = 0.5,
      },
      {
        sprites = { "props/rocks/gray_0.png", "props/rocks/gray_1.png", "props/rocks/gray_2.png", "props/rocks/gray_3.png", "props/rocks/gray_4.png", "props/rocks/gray_5.png", "props/rocks/gray_6.png", "props/rocks/gray_7.png", "props/rocks/gray_8.png", "props/rocks/gray_9.png", "props/rocks/brown_0.png", "props/rocks/brown_1.png", "props/rocks/brown_2.png", "props/rocks/brown_3.png", "props/rocks/brown_4.png", "props/rocks/brown_5.png", "props/rocks/brown_6.png", "props/rocks/brown_7.png", "props/rocks/brown_8.png", "props/rocks/brown_9.png" },
        density = 0.05,
        size = 0.6,
      },
    },
    farmland = {
      {
        sprites = { "props/grass/green_7_0.png", "props/grass/green_7_7.png", "props/grass/green_7_14.png", "props/grass/green_7_21.png", "props/grass/green_7_28.png", "props/grass/green_7_35.png", "props/grass/green_7_42.png", "props/grass/green_7_49.png", "props/grass/green_7_56.png", "props/grass/green_7_63.png", "props/grass/green_7_70.png", "props/grass/green_7_77.png", "props/grass/green_8_0.png", "props/grass/green_8_7.png", "props/grass/green_8_14.png", "props/grass/green_8_21.png", "props/grass/green_8_28.png", "props/grass/green_8_35.png", "props/grass/green_8_42.png", "props/grass/green_8_49.png", "props/grass/green_8_56.png", "props/grass/green_8_63.png", "props/grass/green_8_70.png", "props/grass/green_8_77.png", "props/grass/green_10_0.png", "props/grass/green_10_7.png", "props/grass/green_10_14.png", "props/grass/green_10_21.png", "props/grass/green_10_28.png", "props/grass/green_10_35.png", "props/grass/green_10_42.png", "props/grass/green_10_49.png", "props/grass/green_10_56.png", "props/grass/green_10_63.png", "props/grass/green_10_70.png", "props/grass/green_10_77.png", "props/grass/green_3_0.png", "props/grass/green_3_7.png", "props/grass/green_3_14.png", "props/grass/green_3_21.png", "props/grass/green_3_28.png", "props/grass/green_3_35.png", "props/grass/green_3_42.png", "props/grass/green_3_49.png", "props/grass/green_3_56.png", "props/grass/green_3_63.png", "props/grass/green_3_70.png", "props/grass/green_3_77.png", "props/grass/dry_13_14.png", "props/grass/dry_13_21.png", "props/grass/dry_13_28.png", "props/grass/dry_13_35.png", "props/grass/dry_13_42.png", "props/grass/dry_13_49.png", "props/grass/dry_13_56.png", "props/grass/dry_13_63.png", "props/grass/dry_13_70.png", "props/grass/dry_13_77.png", "props/grass/dry_14_14.png", "props/grass/dry_14_21.png", "props/grass/dry_14_28.png", "props/grass/dry_14_35.png", "props/grass/dry_14_42.png", "props/grass/dry_14_49.png", "props/grass/dry_14_56.png", "props/grass/dry_14_63.png", "props/grass/dry_14_70.png", "props/grass/dry_14_77.png" },
        density = 0.15,
        size = 0.5,
      },
    },
    orchard = {
      {
        sprites = { "props/grass/green_7_0.png", "props/grass/green_7_7.png", "props/grass/green_7_14.png", "props/grass/green_7_21.png", "props/grass/green_7_28.png", "props/grass/green_7_35.png", "props/grass/green_7_42.png", "props/grass/green_7_49.png", "props/grass/green_7_56.png", "props/grass/green_7_63.png", "props/grass/green_7_70.png", "props/grass/green_7_77.png", "props/grass/green_8_0.png", "props/grass/green_8_7.png", "props/grass/green_8_14.png", "props/grass/green_8_21.png", "props/grass/green_8_28.png", "props/grass/green_8_35.png", "props/grass/green_8_42.png", "props/grass/green_8_49.png", "props/grass/green_8_56.png", "props/grass/green_8_63.png", "props/grass/green_8_70.png", "props/grass/green_8_77.png", "props/grass/green_10_0.png", "props/grass/green_10_7.png", "props/grass/green_10_14.png", "props/grass/green_10_21.png", "props/grass/green_10_28.png", "props/grass/green_10_35.png", "props/grass/green_10_42.png", "props/grass/green_10_49.png", "props/grass/green_10_56.png", "props/grass/green_10_63.png", "props/grass/green_10_70.png", "props/grass/green_10_77.png", "props/grass/green_3_0.png", "props/grass/green_3_7.png", "props/grass/green_3_14.png", "props/grass/green_3_21.png", "props/grass/green_3_28.png", "props/grass/green_3_35.png", "props/grass/green_3_42.png", "props/grass/green_3_49.png", "props/grass/green_3_56.png", "props/grass/green_3_63.png", "props/grass/green_3_70.png", "props/grass/green_3_77.png" },
        density = 0.6,
        size = 0.45,
      },
    },
    wetland = {
      {
        sprites = { "props/grass/dry_13_14.png", "props/grass/dry_13_21.png", "props/grass/dry_13_28.png", "props/grass/dry_13_35.png", "props/grass/dry_13_42.png", "props/grass/dry_13_49.png", "props/grass/dry_13_56.png", "props/grass/dry_13_63.png", "props/grass/dry_13_70.png", "props/grass/dry_13_77.png", "props/grass/dry_14_14.png", "props/grass/dry_14_21.png", "props/grass/dry_14_28.png", "props/grass/dry_14_35.png", "props/grass/dry_14_42.png", "props/grass/dry_14_49.png", "props/grass/dry_14_56.png", "props/grass/dry_14_63.png", "props/grass/dry_14_70.png", "props/grass/dry_14_77.png", "props/grass/green_7_0.png", "props/grass/green_7_7.png", "props/grass/green_7_14.png", "props/grass/green_7_21.png", "props/grass/green_7_28.png", "props/grass/green_7_35.png", "props/grass/green_7_42.png", "props/grass/green_7_49.png", "props/grass/green_7_56.png", "props/grass/green_7_63.png", "props/grass/green_7_70.png", "props/grass/green_7_77.png", "props/grass/green_8_0.png", "props/grass/green_8_7.png", "props/grass/green_8_14.png", "props/grass/green_8_21.png", "props/grass/green_8_28.png", "props/grass/green_8_35.png", "props/grass/green_8_42.png", "props/grass/green_8_49.png", "props/grass/green_8_56.png", "props/grass/green_8_63.png", "props/grass/green_8_70.png", "props/grass/green_8_77.png", "props/grass/green_10_0.png", "props/grass/green_10_7.png", "props/grass/green_10_14.png", "props/grass/green_10_21.png", "props/grass/green_10_28.png", "props/grass/green_10_35.png", "props/grass/green_10_42.png", "props/grass/green_10_49.png", "props/grass/green_10_56.png", "props/grass/green_10_63.png", "props/grass/green_10_70.png", "props/grass/green_10_77.png", "props/grass/green_3_0.png", "props/grass/green_3_7.png", "props/grass/green_3_14.png", "props/grass/green_3_21.png", "props/grass/green_3_28.png", "props/grass/green_3_35.png", "props/grass/green_3_42.png", "props/grass/green_3_49.png", "props/grass/green_3_56.png", "props/grass/green_3_63.png", "props/grass/green_3_70.png", "props/grass/green_3_77.png" },
        density = 1.2,
        size = 0.6,
      },
    },
    forest_floor = {
      {
        sprites = { "props/log_summer_0.png", "props/log_summer_1.png", "props/log_summer_2.png", "props/log_summer_3.png" },
        density = 0.08,
        size = 1.2,
      },
      {
        sprites = { "props/stump_summer_0.png", "props/stump_summer_1.png", "props/stump_summer_2.png", "props/stump_summer_3.png" },
        density = 0.1,
        size = 0.8,
      },
      {
        sprites = { "props/bushes/green_0.png", "props/bushes/green_1.png", "props/bushes/green_2.png", "props/bushes/green_3.png", "props/bushes/olive_4.png", "props/bushes/olive_5.png", "props/bushes/olive_6.png", "props/bushes/olive_7.png", "props/bushes/mint_24.png", "props/bushes/mint_25.png", "props/bushes/mint_26.png", "props/bushes/mint_27.png" },
        density = 0.35,
        size = 1.3,
      },
      {
        sprites = { "props/rocks/mossy_10.png", "props/rocks/mossy_11.png", "props/rocks/mossy_12.png", "props/rocks/mossy_13.png", "props/rocks/mossy_14.png", "props/rocks/mossy_15.png", "props/rocks/mossy_16.png", "props/rocks/mossy_17.png", "props/rocks/mossy_18.png", "props/rocks/mossy_19.png" },
        density = 0.08,
        size = 1.0,
      },
      {
        sprites = { "props/grass/green_7_0.png", "props/grass/green_7_7.png", "props/grass/green_7_14.png", "props/grass/green_7_21.png", "props/grass/green_7_28.png", "props/grass/green_7_35.png", "props/grass/green_7_42.png", "props/grass/green_7_49.png", "props/grass/green_7_56.png", "props/grass/green_7_63.png", "props/grass/green_7_70.png", "props/grass/green_7_77.png", "props/grass/green_8_0.png", "props/grass/green_8_7.png", "props/grass/green_8_14.png", "props/grass/green_8_21.png", "props/grass/green_8_28.png", "props/grass/green_8_35.png", "props/grass/green_8_42.png", "props/grass/green_8_49.png", "props/grass/green_8_56.png", "props/grass/green_8_63.png", "props/grass/green_8_70.png", "props/grass/green_8_77.png", "props/grass/green_10_0.png", "props/grass/green_10_7.png", "props/grass/green_10_14.png", "props/grass/green_10_21.png", "props/grass/green_10_28.png", "props/grass/green_10_35.png", "props/grass/green_10_42.png", "props/grass/green_10_49.png", "props/grass/green_10_56.png", "props/grass/green_10_63.png", "props/grass/green_10_70.png", "props/grass/green_10_77.png", "props/grass/green_3_0.png", "props/grass/green_3_7.png", "props/grass/green_3_14.png", "props/grass/green_3_21.png", "props/grass/green_3_28.png", "props/grass/green_3_35.png", "props/grass/green_3_42.png", "props/grass/green_3_49.png", "props/grass/green_3_56.png", "props/grass/green_3_63.png", "props/grass/green_3_70.png", "props/grass/green_3_77.png" },
        density = 0.3,
        size = 0.45,
      },
    },
    rock = {
      {
        sprites = { "props/rocks/gray_20.png", "props/rocks/gray_21.png", "props/rocks/gray_22.png", "props/rocks/gray_23.png", "props/rocks/gray_24.png", "props/rocks/gray_25.png", "props/rocks/gray_26.png", "props/rocks/gray_27.png", "props/rocks/gray_28.png", "props/rocks/gray_29.png", "props/rocks/gray_30.png", "props/rocks/gray_32.png", "props/rocks/gray_36.png", "props/rocks/gray_38.png", "props/rocks/gray_39.png", "props/rocks/gray_40.png", "props/rocks/gray_41.png", "props/rocks/gray_42.png", "props/rocks/gray_43.png", "props/rocks/gray_47.png", "props/rocks/gray_48.png", "props/rocks/gray_49.png", "props/rocks/granite_20.png", "props/rocks/granite_21.png", "props/rocks/granite_22.png", "props/rocks/granite_23.png", "props/rocks/granite_24.png", "props/rocks/granite_25.png", "props/rocks/granite_26.png", "props/rocks/granite_27.png", "props/rocks/granite_28.png", "props/rocks/granite_29.png", "props/rocks/granite_30.png", "props/rocks/granite_32.png", "props/rocks/granite_36.png", "props/rocks/granite_38.png", "props/rocks/granite_39.png", "props/rocks/granite_40.png", "props/rocks/granite_41.png", "props/rocks/granite_42.png", "props/rocks/granite_43.png", "props/rocks/granite_47.png", "props/rocks/granite_48.png", "props/rocks/granite_49.png", "props/rocks/slate_20.png", "props/rocks/slate_21.png", "props/rocks/slate_22.png", "props/rocks/slate_23.png", "props/rocks/slate_24.png", "props/rocks/slate_25.png", "props/rocks/slate_26.png", "props/rocks/slate_27.png", "props/rocks/slate_28.png", "props/rocks/slate_29.png", "props/rocks/slate_30.png", "props/rocks/slate_32.png", "props/rocks/slate_36.png", "props/rocks/slate_38.png", "props/rocks/slate_39.png", "props/rocks/slate_40.png", "props/rocks/slate_41.png", "props/rocks/slate_42.png", "props/rocks/slate_43.png", "props/rocks/slate_47.png", "props/rocks/slate_48.png", "props/rocks/slate_49.png" },
        density = 0.25,
        size = 2.4,
      },
      {
        sprites = { "props/rocks/gray_10.png", "props/rocks/gray_11.png", "props/rocks/gray_12.png", "props/rocks/gray_13.png", "props/rocks/gray_14.png", "props/rocks/gray_15.png", "props/rocks/gray_16.png", "props/rocks/gray_17.png", "props/rocks/gray_18.png", "props/rocks/gray_19.png", "props/rocks/granite_10.png", "props/rocks/granite_11.png", "props/rocks/granite_12.png", "props/rocks/granite_13.png", "props/rocks/granite_14.png", "props/rocks/granite_15.png", "props/rocks/granite_16.png", "props/rocks/granite_17.png", "props/rocks/granite_18.png", "props/rocks/granite_19.png", "props/rocks/slate_10.png", "props/rocks/slate_11.png", "props/rocks/slate_12.png", "props/rocks/slate_13.png", "props/rocks/slate_14.png", "props/rocks/slate_15.png", "props/rocks/slate_16.png", "props/rocks/slate_17.png", "props/rocks/slate_18.png", "props/rocks/slate_19.png", "props/rocks/dark_gray_10.png", "props/rocks/dark_gray_11.png", "props/rocks/dark_gray_12.png", "props/rocks/dark_gray_13.png", "props/rocks/dark_gray_14.png", "props/rocks/dark_gray_15.png", "props/rocks/dark_gray_16.png", "props/rocks/dark_gray_17.png", "props/rocks/dark_gray_18.png", "props/rocks/dark_gray_19.png" },
        density = 0.35,
        size = 1.2,
      },
      {
        sprites = { "props/rocks/gray_0.png", "props/rocks/gray_1.png", "props/rocks/gray_2.png", "props/rocks/gray_3.png", "props/rocks/gray_4.png", "props/rocks/gray_5.png", "props/rocks/gray_6.png", "props/rocks/gray_7.png", "props/rocks/gray_8.png", "props/rocks/gray_9.png", "props/rocks/slate_0.png", "props/rocks/slate_1.png", "props/rocks/slate_2.png", "props/rocks/slate_3.png", "props/rocks/slate_4.png", "props/rocks/slate_5.png", "props/rocks/slate_6.png", "props/rocks/slate_7.png", "props/rocks/slate_8.png", "props/rocks/slate_9.png" },
        density = 0.6,
        size = 0.6,
      },
    },
    scrub = {
      {
        sprites = { "props/bushes/green_0.png", "props/bushes/green_1.png", "props/bushes/green_2.png", "props/bushes/green_3.png", "props/bushes/olive_4.png", "props/bushes/olive_5.png", "props/bushes/olive_6.png", "props/bushes/olive_7.png", "props/bushes/mint_24.png", "props/bushes/mint_25.png", "props/bushes/mint_26.png", "props/bushes/mint_27.png" },
        density = 0.8,
        size = 1.4,
      },
      {
        sprites = { "props/bushes/pink_8.png", "props/bushes/pink_9.png", "props/bushes/pink_10.png", "props/bushes/pink_11.png" },
        density = 0.12,
        size = 1.2,
      },
      {
        sprites = { "props/rocks/brown_0.png", "props/rocks/brown_1.png", "props/rocks/brown_2.png", "props/rocks/brown_3.png", "props/rocks/brown_4.png", "props/rocks/brown_5.png", "props/rocks/brown_6.png", "props/rocks/brown_7.png", "props/rocks/brown_8.png", "props/rocks/brown_9.png", "props/rocks/gray_0.png", "props/rocks/gray_1.png", "props/rocks/gray_2.png", "props/rocks/gray_3.png", "props/rocks/gray_4.png", "props/rocks/gray_5.png", "props/rocks/gray_6.png", "props/rocks/gray_7.png", "props/rocks/gray_8.png", "props/rocks/gray_9.png" },
        density = 0.1,
        size = 0.6,
      },
    },
    sand = {
      {
        sprites = { "props/rocks/sandstone_0.png", "props/rocks/sandstone_1.png", "props/rocks/sandstone_2.png", "props/rocks/sandstone_3.png", "props/rocks/sandstone_4.png", "props/rocks/sandstone_5.png", "props/rocks/sandstone_6.png", "props/rocks/sandstone_7.png", "props/rocks/sandstone_8.png", "props/rocks/sandstone_9.png", "props/rocks/sand_beige_0.png", "props/rocks/sand_beige_1.png", "props/rocks/sand_beige_2.png", "props/rocks/sand_beige_3.png", "props/rocks/sand_beige_4.png", "props/rocks/sand_beige_5.png", "props/rocks/sand_beige_6.png", "props/rocks/sand_beige_7.png", "props/rocks/sand_beige_8.png", "props/rocks/sand_beige_9.png" },
        density = 0.12,
        size = 0.5,
      },
    },
    dry_grass = {
      {
        sprites = { "props/bushes/olive_4.png", "props/bushes/olive_5.png", "props/bushes/olive_6.png", "props/bushes/olive_7.png" },
        density = 0.25,
        size = 1.1,
      },
      {
        sprites = { "props/grass/dry_13_14.png", "props/grass/dry_13_21.png", "props/grass/dry_13_28.png", "props/grass/dry_13_35.png", "props/grass/dry_13_42.png", "props/grass/dry_13_49.png", "props/grass/dry_13_56.png", "props/grass/dry_13_63.png", "props/grass/dry_13_70.png", "props/grass/dry_13_77.png", "props/grass/dry_14_14.png", "props/grass/dry_14_21.png", "props/grass/dry_14_28.png", "props/grass/dry_14_35.png", "props/grass/dry_14_42.png", "props/grass/dry_14_49.png", "props/grass/dry_14_56.png", "props/grass/dry_14_63.png", "props/grass/dry_14_70.png", "props/grass/dry_14_77.png", "props/grass/yellow_21_0.png", "props/grass/yellow_21_7.png", "props/grass/yellow_21_14.png", "props/grass/yellow_21_21.png", "props/grass/yellow_21_28.png", "props/grass/yellow_21_35.png", "props/grass/yellow_21_42.png", "props/grass/yellow_21_49.png", "props/grass/yellow_21_56.png", "props/grass/yellow_21_63.png", "props/grass/yellow_21_70.png", "props/grass/yellow_21_77.png", "props/grass/yellow_23_0.png", "props/grass/yellow_23_7.png", "props/grass/yellow_23_14.png", "props/grass/yellow_23_21.png", "props/grass/yellow_23_28.png", "props/grass/yellow_23_35.png", "props/grass/yellow_23_42.png", "props/grass/yellow_23_49.png", "props/grass/yellow_23_56.png", "props/grass/yellow_23_63.png", "props/grass/yellow_23_70.png", "props/grass/yellow_23_77.png" },
        density = 1.0,
        size = 0.5,
      },
    },
  },
  buildings = {
    facades = "buildings/facades.png",
    styles = 6,
    bay_metres = 2.9,
    floor_metres = 3.2,
    ground_floor_metres = 4.2,
    roofs = { "buildings/roof_tiles.png" },
    roof_tints = {
      { 1, 1, 1 },
      { 1, 1, 1 },
      { 1, 1, 1 },
      { 0.62, 0.68, 0.78 },
      { 0.55, 0.58, 0.62 },
      { 1.05, 0.95, 0.85 },
    },
  },
  bridge = {
    side = "#b9a88f",
    wall = "bridge/brick_1.png",
    stone = "bridge/stone_1.png",
    parapet = "bridge/parapet_1.png",
    arch = "bridge/arch_1.png",
    tile_metres = 1.5,
    parapet_height = 1.0,
    deck_thickness = 0.7,
  },
  filter = {
    pixel = 3,
    colours = 64,
  },
  rider = {
    jersey = "#c8392f",
    shorts = "#1f1f24",
    skin = "#e3b48f",
    helmet = "#f2f2f2",
  },
  bikes = {
    mtb = {
      texture = "bikes/bike_basecolor.png",
    },
  },
}
