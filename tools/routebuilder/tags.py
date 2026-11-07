"""Semantic ground tags. Route files store these ids; asset packs decide what each one looks like."""

TAGS = ['urban', 'grass', 'scrub', 'water', 'asphalt', 'paving', 'cobble', 'gravel', 'sand', 'cycleway',
        'dirt', 'rail', 'pitch', 'farmland', 'forest_floor', 'meadow', 'rock', 'snow', 'wetland', 'orchard',
        'rural', 'parking', 'dry_grass']
ID = {t: i for i, t in enumerate(TAGS)}

# draw order for areas (low first); roads are drawn after all areas
AREA_RANK = {'rural': 0, 'urban': 0, 'meadow': 1, 'farmland': 1, 'dry_grass': 1, 'forest_floor': 2, 'scrub': 2,
             'orchard': 2, 'wetland': 2, 'rock': 2, 'snow': 3, 'grass': 3, 'sand': 4, 'pitch': 5, 'dirt': 5,
             'parking': 6, 'paving': 6, 'rail': 6, 'water': 7}


def area_tag(g):
    lu, nat, lei, am = g.get('landuse'), g.get('natural'), g.get('leisure'), g.get('amenity')
    if nat == 'water' or g.get('water') or lu in ('basin', 'reservoir') or g.get('waterway') == 'riverbank' or am == 'fountain':
        return 'water'
    if nat in ('wood',) or lu == 'forest': return 'forest_floor'
    if nat in ('scrub', 'shrubbery'): return 'scrub'
    if nat in ('heath',): return 'dry_grass'
    if nat in ('grassland',) or lu in ('meadow',): return 'meadow'
    if nat in ('sand', 'beach', 'dune') or lei in ('playground', 'beach_resort'): return 'sand'
    if nat in ('bare_rock', 'scree', 'shingle', 'cliff', 'rock', 'stone') or lu == 'quarry': return 'rock'
    if nat == 'glacier': return 'snow'
    if nat == 'wetland': return 'wetland'
    if lu in ('grass', 'greenery', 'flowerbed', 'village_green', 'recreation_ground', 'cemetery') or lei in ('park', 'garden', 'golf_course', 'dog_park'):
        return 'grass'
    if lu == 'farmland': return 'farmland'
    if lu in ('orchard', 'vineyard', 'allotments', 'plant_nursery'): return 'orchard'
    if lu in ('farmyard', 'construction', 'brownfield', 'landfill') or lei in ('track',): return 'dirt'
    if lei in ('pitch', 'sports_centre', 'stadium'): return 'pitch'
    if am == 'parking' or g.get('area:highway'): return 'parking'
    if g.get('highway') in ('pedestrian', 'footway') and g.get('area') == 'yes': return 'paving'
    if lu in ('residential', 'commercial', 'retail', 'industrial', 'garages', 'railway', 'education', 'institutional'):
        return 'urban'
    return None


# highway -> (tag, width m, sidewalk width m each side)
ROADS = {
    'motorway': ('asphalt', 16, 0), 'trunk': ('asphalt', 14, 1), 'primary': ('asphalt', 11, 2.5), 'secondary': ('asphalt', 9.5, 2.5),
    'tertiary': ('asphalt', 8, 2), 'unclassified': ('asphalt', 5.5, 0), 'residential': ('asphalt', 6.5, 2),
    'living_street': ('cobble', 6, 0), 'service': ('asphalt', 4, 0), 'pedestrian': ('paving', 6, 0),
    'footway': ('paving', 2.5, 0), 'steps': ('paving', 2.5, 0), 'cycleway': ('cycleway', 2.5, 0),
    'path': ('dirt', 1.8, 0), 'track': ('gravel', 3, 0), 'bridleway': ('dirt', 2, 0),
    'motorway_link': ('asphalt', 7, 0), 'trunk_link': ('asphalt', 7, 0), 'primary_link': ('asphalt', 7, 0),
    'secondary_link': ('asphalt', 7, 0), 'tertiary_link': ('asphalt', 6, 0), 'road': ('asphalt', 6, 0),
}
SURFACE = {'asphalt': 'asphalt', 'paved': 'asphalt', 'concrete': 'paving', 'concrete:plates': 'paving',
           'paving_stones': 'paving', 'sett': 'cobble', 'cobblestone': 'cobble', 'unhewn_cobblestone': 'cobble',
           'gravel': 'gravel', 'fine_gravel': 'gravel', 'compacted': 'gravel', 'pebblestone': 'gravel',
           'dirt': 'dirt', 'ground': 'dirt', 'earth': 'dirt', 'mud': 'dirt', 'unpaved': 'gravel', 'sand': 'sand',
           'grass': 'grass', 'wood': 'paving', 'rock': 'rock'}


def road_tag(g):
    hw = g.get('highway')
    if hw not in ROADS: return None
    tag, w, sw = ROADS[hw]
    surf = g.get('surface')
    if surf in SURFACE and hw != 'cycleway': tag = SURFACE[surf]
    if hw == 'track' and g.get('tracktype') in ('grade4', 'grade5') and surf is None: tag = 'dirt'
    try: w = float(str(g.get('width', w)).split()[0])
    except ValueError: pass
    return tag, w, sw


# what a rider would call the surface (for the route summary and bike recommendation)
RIDE_SURFACE = {'asphalt': 'asphalt', 'cycleway': 'asphalt', 'paving': 'paved', 'cobble': 'cobbles',
                'gravel': 'gravel', 'dirt': 'dirt', 'sand': 'sand', 'grass': 'grass', 'rock': 'rock'}
