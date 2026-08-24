extends Node

## Shared gameplay constants and level-scaling helpers for Bastion Bomber.

const LEVEL_COUNT := 20

## Airframes are bound to level bands — you earn a new wing as the campaign advances.
enum PlaneType { GUNSHIP, BOMBER, STRIKE, CARPET }

const PLANE_TYPE_NAMES := {
	PlaneType.GUNSHIP: "GUNSHIP",
	PlaneType.BOMBER: "BOMBER",
	PlaneType.STRIKE: "STRIKE",
	PlaneType.CARPET: "CARPET",
}

## Sprite tint per airframe so the wing reads at a glance.
const PLANE_TYPE_TINTS := {
	PlaneType.GUNSHIP: Color(0.72, 0.86, 0.58),
	PlaneType.BOMBER: Color(1.0, 1.0, 1.0),
	PlaneType.STRIKE: Color(0.62, 0.78, 1.0),
	PlaneType.CARPET: Color(1.0, 0.6, 0.48),
}

## Visual silhouette only — Area2D scale stays fixed so hitboxes stay fair.
const PLANE_TYPE_SPRITE_SCALES := {
	PlaneType.GUNSHIP: Vector2(1.05, 1.05),
	PlaneType.BOMBER: Vector2(1.18, 1.18),
	PlaneType.STRIKE: Vector2(1.1, 1.1),
	PlaneType.CARPET: Vector2(1.3, 1.3),
}

const GUNSHIP_MAX_LEVEL := 5
const BOMBER_MAX_LEVEL := 10
const STRIKE_MAX_LEVEL := 15

## Gunship (levels 1–5): hunts corner AA first, strafes with its nose gun.
const GUNSHIP_STRAFE_RANGE := 250.0
const GUNSHIP_SHOT_COUNT := 5
const GUNSHIP_SHOT_DAMAGE := 4  # 5 × 4 = 20, same payload as one bomb
const GUNSHIP_SHOT_INTERVAL := 0.16
const GUNSHIP_SHOT_JITTER := 28.0
const GUNSHIP_SPEED_MULT := 1.08

## Strike jet (levels 11–15): fires a guided missile from standoff, then banks away.
## Standoff still sits inside AA reach so the run in and out is a gamble, but it
## has to scale with that reach: corner guns now cover up to 470, and launching
## at the old 160 meant the jets flew almost to the keep before releasing, which
## is the bomber's job and got them killed doing it.
##
## Trimming this to 185 was tried, on the theory that a jet releasing before it
## was properly under the guns is why sector slew never punishes repetition in
## this band. It measured worse on both counts — a locked bearing went from
## taking bastion 15 on 2 seeds of 2 to 3 of 3, and adaptive play tightened to
## 64-100% of the wing — so the standoff is left alone.
const STRIKE_STANDOFF := 230.0
const STRIKE_MISSILE_DAMAGE := 20
const STRIKE_MISSILE_SPEED := 300.0
const STRIKE_MISSILE_TURN_RATE := 4.5
const STRIKE_SPEED_MULT := 1.15

## Bomber (levels 6–10): must overfly the keep — needs pace to punch through AA.
## Trimming this to 1.22 was tried, on the theory that a bomber crossing the
## contested band faster than a gun's target-lock window is what lets a repeated
## bearing go unpunished. It measured worse and noisier at the bomber
## stronghold, so it is left alone.
const BOMBER_SPEED_MULT := 1.35

## Carpet bomber (levels 16–20): one plane lays 3 bombs along the keep track.
const CARPET_BOMB_COUNT := 3
const CARPET_BOMB_DAMAGE := 10
const CARPET_BOMB_INTERVAL := 0.22
const CARPET_BOMB_SPACING := 36.0
## Where the run begins. The stick always walks across the keep itself, so this
## sets how much fortress the bird has to cross *before* its payload is away —
## not where the bombs land. It has to scale with the island: on the level 20
## stronghold a 170 start meant crossing ~330 px of covered water first, on a
## locked heading, which is the one thing a leading gunner solves perfectly.
## The wing was losing whole squadrons without the keep taking a scratch.
##
## Pulled back from 265 once the keep and the squadron were retuned. At 265 the
## bird committed its payload before it ever reached the deep fort, so a carpet
## run barely had to survive anything — measured, a locked-bearing column landed
## 53% of its sticks on the finale and beat adaptive flanking. The 265 figure was
## calibrated against a keep with a fifth of its current HP and a squadron the
## wing could afford to throw away.
const CARPET_START_RANGE := 205.0
## Carpet bombers overfly the whole fort on a locked heading, which makes them
## the easiest airframe for a leading gunner to solve. They need the pace to
## survive the run they are forced to make.
const CARPET_SPEED_MULT := 1.2

## --- Decoy drones ---------------------------------------------------------
##
## The player's only verb used to be *where*: read which water is cold, tap it.
## That makes the fortress the active party and the squadron the reactive one,
## and it is why a 48-bird siege is 48 near-identical decisions.
##
## The fort already commits each gun to one bird for TURRET_TARGET_LOCK_TIME and
## slews whole sectors toward sustained pressure. A decoy turns both of those
## from things the player reads into things the player causes: spend a charge to
## pull the north mounts off their corner, then push the real wave through the
## hole it leaves. Same fortress, second verb.
##
## Decoys carry no ordnance and cost no squadron — but they do leave the same
## deck, so they consume a scramble gap. That is what keeps the choice real: a
## decoy is paid for with a bomber's slot in time, not with nothing.
const DECOY_MAX_CHARGES := 3
const DECOY_START_CHARGES := 2
const DECOY_RECHARGE_SEC := 11.0
## Hits before it goes down. A one-hit decoy dies to the first bullet and buys
## nothing at all; three is what makes it hold a lock long enough for the next
## two or three birds to be the point.
const DECOY_HITS := 3
## Seconds it will loiter before turning for home. Long enough to drag a sector
## most of the way across its slew span, short enough that a charge spent on the
## wrong side is a mistake the player has to live with.
const DECOY_LIFETIME := 7.5
const DECOY_SPEED_MULT := 0.82
## How much closer to a gunner a decoy looks than it really is. Gun target
## selection is nearest-first, so the lure is a distance discount rather than a
## separate priority pass — it stays a preference, not an override, and a bomber
## flying right down a barrel is still the shot the crew takes.
const DECOY_LURE_BIAS := 0.55
## Loiter radius as a fraction of the corner guns' reach. Deep enough to sit
## well inside the AA envelope and keep pulling, shallow enough that it is not
## simply orbiting inside the fort.
const DECOY_ORBIT_FRACTION := 0.62
## Floor on that radius so a decoy never tries to loiter on the beach.
const DECOY_ORBIT_MIN_MARGIN := 40.0
const DECOY_TINT := Color(1.0, 0.86, 0.42)
const DECOY_SPRITE_SCALE := Vector2(0.92, 0.92)

## --- Interceptors ---------------------------------------------------------
##
## The fort's own mobile defender, and the answer to the one gate that numbers
## could not close.
##
## Every emplacement in the game is *static*: a mount can slew its sector but it
## cannot leave its corner. That is why the finale resisted nine rounds of
## tuning — with fixed guns, flying the same bearing repeatedly and flying a
## different one each time cost within ~10% of each other, so no squadron size
## or HP curve could tell good play from bad. Discrimination has to be
## positional, and only something that can *move to where you keep attacking*
## provides it.
##
## An interceptor launches from the keep, flies to whichever water the raid is
## pressing, and holds there. Lean on one bearing and they stack up on it. Move,
## and they have to transit — and transit is dead time, which is the whole
## counterplay. They are lurable by decoys on the same terms as every other
## defender, so the feint layer answers them too.
##
## Introduced at 17. Tried at 15 and reverted: it made bastion 15 harder for
## everyone (adaptive play went to 84-100% of the wing, one seed spending all of
## it) without reliably closing the gate there — a locked bearing still took one
## seed in three. That is the same way the finale experiment failed. Interceptors
## raise the floor; they do not by themselves separate two strategies when the
## wing barely enters the contested band at all.
##
## Bastion 20 is deliberately excluded. The finale already runs a maximal fort —
## the largest island, the thickest outer ring, the longest reach and the highest
## keep HP in the campaign — and interceptors on top of that measured unwinnable
## by adaptive play in 6 of 6 runs across two strength settings. The finale's
## identity is the fortress itself; this is the late band's threat, not its.
const INTERCEPTOR_UNLOCK_LEVEL := 17
const INTERCEPTOR_MAX_LEVEL := 19
## Live at once, by level. Kept small — these are a positional threat, not a
## damage race, and a swarm of them would just make the finale unwinnable.
## Two is the measured value: at bastions 17-19 it makes a locked bearing fail
## 3 of 3 while adaptive play wins 3 of 3, which is the campaign's rule holding
## on its own merits for the first time anywhere in the game.
const INTERCEPTOR_MAX_ALIVE := 2
const INTERCEPTOR_LAUNCH_INTERVAL := 6.0
## First one is airborne shortly after the siege opens, so the player meets the
## mechanic while they still have a wing to learn it with.
const INTERCEPTOR_FIRST_LAUNCH := 4.0
const INTERCEPTOR_SPEED := 205.0
## Slower than every attacking wing. It has to be: an interceptor that can run a
## bomber down from behind removes the counterplay, which is that changing
## bearing makes them spend their time travelling instead of shooting.
const INTERCEPTOR_HP := 12
const INTERCEPTOR_ENGAGE_RANGE := 150.0
const INTERCEPTOR_FIRE_COOLDOWN := 1.7
## How far out it will hold station from the keep while hunting.
const INTERCEPTOR_PATROL_RADIUS := 300.0
## Seconds it stays committed to one bird, matching the corner guns so the whole
## fortress reads the same way.
const INTERCEPTOR_LOCK_TIME := 1.25
const INTERCEPTOR_TINT := Color(0.85, 0.38, 0.42)

## Stronghold evolution — staggered so no level introduces two new things.
const MISSILE_TOWER_UNLOCK_LEVEL := 4
const FLAK_TOWER_UNLOCK_LEVEL := 13

## Flak battery: shell bursts at the plane's predicted spot, hits everything nearby.
const FLAK_RANGE := 300.0
const FLAK_COOLDOWN := 2.4
const FLAK_SHELL_SPEED := 320.0
const FLAK_BURST_RADIUS := 60.0

## Squadron size is calibrated per wing rather than on one global ramp: a
## gunship puts a fraction of a bomb on the keep, a carpet run puts three, and
## the airframes lose birds at very different rates. Values come from measured
## well-flown runs (tools/balance_check.sh) and are sized so a good siege ends
## with roughly a third of the wing spare while a sloppy one runs dry — which
## is what makes an individual deploy worth thinking about.
## Vector2i(size at the wing's first level, growth per level within the band).
## Sized from the measured rendered matrix so a well-flown siege spends about
## two thirds of the wing. The old numbers were 3–4x oversized: `flank` cleared
## the bastion 10 stronghold on 12 birds of 54 and the finale on 16 of 76, which
## is the failure the design-gates skill names outright — if a level falls to a
## third of its squadron, losses never bite and no placement decision can show
## up in the result.
##
## The late bands are the largest because scaling the fort with its island moved
## the guns out to a real defensive ring, and delivery on the big strongholds
## fell with it: at the previous sizes adaptive play spent its whole wing on the
## finale three seeds out of three and still left the keep standing. These are
## the sizes that put good play back at roughly two thirds.
const SQUADRON_BY_WING := {
	PlaneType.GUNSHIP: Vector2i(44, 4),  # levels 1–5   → 44..60
	PlaneType.BOMBER: Vector2i(46, 3),   # levels 6–10  → 46..58
	PlaneType.STRIKE: Vector2i(56, 5),   # levels 11–15 → 56..76
	PlaneType.CARPET: Vector2i(62, 5),   # levels 16–20 → 62..82
}
const SQUADRON_BASE := 44
## Alias for level-1 squadron (playtest / HUD defaults).
const SQUADRON_SIZE := SQUADRON_BASE

## Fractions of the squadron a win may cost for each star rating. Deriving the
## bands from the squadron rather than from a theoretical damage-per-plane
## figure keeps them honest: the old model assumed every bird delivered, so
## three stars sat at roughly half the plane count anyone can actually achieve.
const THREE_STAR_FRACTION := 0.55
const TWO_STAR_FRACTION := 0.8

## Keep HP had not kept pace with the wings. Payload per bird roughly triples
## across the campaign (a gunship puts ~5 on the keep, a carpet stick puts ~11)
## while the keep only went 100 → 176, so every later bastion was cheaper in
## ordnance than the one before it. Measured against the rendered matrix, this
## curve is what makes a good siege spend most of its wing and run 30s+ rather
## than resolving in twelve seconds.
const KEEP_MAX_HP := 170
const KEEP_HP_PER_LEVEL := 17  # level 20 → 170 + 323 = 493
const KEEP_BOMB_DAMAGE := 20
## Emplacements have to be worth more than two bombs, or a longer siege simply
## suppresses the whole ring early and flies the back half unopposed — which
## would hand a fixed bearing the win by attrition instead of by placement.
## Three bombs is the measured sweet spot: 85 was tried first and made the
## bomber strongholds unwinnable, because bombs incidentally clearing the ring
## is most of what keeps delivery viable over a long siege — at five bombs a gun
## the ring never thinned and delivery collapsed from 42% to 15%.
const TURRET_MAX_HP := 60
const TURRET_BOMB_DAMAGE := 20

const PLANE_SPEED := 220.0
const PLANE_BOMB_RADIUS := 70.0
## Body scale for the Area2D; sprites size up further via PLANE_TYPE_SPRITE_SCALES.
const PLANE_SCALE := 1.05
## Flight contrail cadence (seconds between puffs while airborne).
const PLANE_TRAIL_INTERVAL := 0.07

## Gap between birds leaving the deck — lighter wings scramble faster. This
## applies to every deploy, taps included: it is the game's only resource clock,
## so it also sets how long the player has to read the board between decisions.
## Fast enough to keep a siege flowing, slow enough that a deploy is a choice
## rather than a reflex.
const PLANE_DEPLOY_INTERVALS := {
	PlaneType.STRIKE: 0.5,
	PlaneType.GUNSHIP: 0.62,
	PlaneType.BOMBER: 0.75,
	PlaneType.CARPET: 1.0,
}

const TURRET_RANGE := 360.0
const TURRET_FIRE_COOLDOWN := 1.2
## Corner guns reach farther from bastion 3, and cycle faster from bastion 5.
## Staggered on purpose: landing both upgrades on the same level alongside the
## third gun and a denser tower ring made bastion 3 a wall, and broke the
## one-new-thing-per-level rule four ways at once.
const TURRET_RANGE_HOT := 410.0
const TURRET_FIRE_COOLDOWN_HOT := 0.75
const TURRET_COOLDOWN_HOT_LEVEL := 5
## Depth of covered water a corner gun holds beyond its own shoreline. Islands
## nearly double in radius across the campaign; a flat range meant that by the
## late strongholds the AA envelope stopped short of the sea entirely, so the
## approach was never contested and choosing where to come in stopped mattering.
## Scaling reach with the island keeps the corridor a real, readable space.
const TURRET_WATER_REACH := 105.0
## Ceiling on that growth. Without it the late strongholds reach clear across
## the screen, which both erases the cold water the tactic depends on and makes
## the deep run a carpet wing has to fly simply unsurvivable.
##
## Raised from 470 on measurement: at 470 the finale was not contested at all —
## a locked-bearing column beat adaptive flanking there (29 birds against 43),
## which is the exact opposite of the campaign's load-bearing rule. On a 460
## island the mounts sit close enough to the middle that a 470 reach left the
## approach water outside everyone's envelope, so no amount of sector slew could
## answer a fixed heading.
const TURRET_RANGE_CAP := 560.0
## Extra reach the milestone strongholds hold beyond the normal curve.
##
## Removal was tested once and rejected — but that verdict came off the
## wall-clock harness, before runs were reproducible, so it was drawn from noise
## and is being re-tested rather than trusted. The theory it was rejecting is
## still the live one: this was a workaround for mounts that did not scale with
## their island, and now that the fort scales, blanketing every bearing with
## reach erases the cold water the whole tactic reads.
const TURRET_STRONGHOLD_REACH := 0.0
const TURRET_ROTATE_SPEED := 3.5
## How fast a barrel swings, rad/s. Deliberately slower than a plane's run: a
## gun facing the wrong way stays wrong for long enough that the player can
## spend that window, which is what makes tap placement a decision at all.
const TURRET_TRAVERSE_SPEED := 1.5
## Seconds a gun stays committed to one bird before re-picking. Long enough
## that a decoy on the far side actually pulls the barrel off your real run.
const TURRET_TARGET_LOCK_TIME := 1.25
const BULLET_SPEED := 380.0
const BULLET_DAMAGE := 1

## Outer defense towers (procedural, smaller than keep AA).
const TOWER_MAX_HP := 45
const TOWER_BOMB_DAMAGE := 20
const TOWER_MG_RANGE := 200.0
const TOWER_MG_COOLDOWN := 0.45
const TOWER_MISSILE_RANGE := 310.0
const TOWER_MISSILE_COOLDOWN := 2.8
const MISSILE_SPEED := 210.0
const MISSILE_TURN_RATE := 2.8
const MISSILE_DAMAGE := 3
const MISSILE_LIFETIME := 4.0

## Soft cloud banks + ocean shadows. Off for now — they muddy plane/AA readability.
const CLOUDS_ENABLED := false

## Legacy single-island defaults (level-1 center / radius). Prefer runtime active center.
const ISLAND_CENTER := Vector2(360, 640)
const ISLAND_RADIUS := 240.0
const ISLAND_RADIUS_MAX := 380.0
## Milestone bastions (10 / 15 / 20) punch above the normal size curve.
const ISLAND_RADIUS_STRONGHOLD := 460.0
const KEEP_RADIUS := 90.0
const FORT_CLEAR_RADIUS := 110.0
## Ceiling on fort growth, so the finale's fortress fills its isle without
## swallowing the grass the outer ring and the palms need.
const FORT_SCALE_MAX := 1.95
const WATER_MIN_RADIUS := 255.0
## Guns stay this far inside the grass line so they don't sit on the beach.
const TOWER_INLAND_MARGIN := 52.0

const ISLAND_SPACING_MIN := 1400.0
const ISLAND_SPACING_MAX := 1800.0
const CAMERA_PAN_DURATION := 1.2

## Empty tropical islets between bastions — scenery only, no guns.
const SCENIC_ISLAND_COUNT_MIN := 8
const SCENIC_ISLAND_COUNT_MAX := 12
const SCENIC_RADIUS_MIN := 55.0
const SCENIC_RADIUS_MAX := 135.0
const SCENIC_SEP_FROM_BASTION := 560.0
const SCENIC_SEP_FROM_SCENIC := 400.0

## Campaign milestones: oversized islands with denser outer defenses.
const STRONGHOLD_LEVELS := [10, 15, 20]


func level_t(level: int) -> float:
	var n := clampi(level, 1, LEVEL_COUNT)
	if LEVEL_COUNT <= 1:
		return 0.0
	return float(n - 1) / float(LEVEL_COUNT - 1)


func is_stronghold_level(level: int) -> bool:
	return clampi(level, 1, LEVEL_COUNT) in STRONGHOLD_LEVELS


## First campaign level that flies the given wing.
func wing_band_start(plane_type: PlaneType) -> int:
	match plane_type:
		PlaneType.BOMBER:
			return GUNSHIP_MAX_LEVEL + 1
		PlaneType.STRIKE:
			return BOMBER_MAX_LEVEL + 1
		PlaneType.CARPET:
			return STRIKE_MAX_LEVEL + 1
		_:
			return 1


func squadron_for_level(level: int) -> int:
	var n := clampi(level, 1, LEVEL_COUNT)
	var wing := plane_type_for_level(n)
	var spec: Vector2i = SQUADRON_BY_WING[wing]
	return spec.x + (n - wing_band_start(wing)) * spec.y


func plane_type_for_level(level: int) -> PlaneType:
	var n := clampi(level, 1, LEVEL_COUNT)
	if n <= GUNSHIP_MAX_LEVEL:
		return PlaneType.GUNSHIP
	if n <= BOMBER_MAX_LEVEL:
		return PlaneType.BOMBER
	if n <= STRIKE_MAX_LEVEL:
		return PlaneType.STRIKE
	return PlaneType.CARPET


func plane_name_for_level(level: int) -> String:
	return PLANE_TYPE_NAMES[plane_type_for_level(level)]


func deploy_interval_for_plane(plane_type: PlaneType) -> float:
	return PLANE_DEPLOY_INTERVALS.get(plane_type, PLANE_DEPLOY_INTERVALS[PlaneType.BOMBER])


func deploy_interval_for_level(level: int) -> float:
	return deploy_interval_for_plane(plane_type_for_level(level))


func island_radius_for_level(level: int) -> float:
	var n := clampi(level, 1, LEVEL_COUNT)
	if is_stronghold_level(n):
		# 10 / 15 / 20 step up so the finale feels like a real fortress isle.
		if n == 10:
			return lerpf(ISLAND_RADIUS_MAX, ISLAND_RADIUS_STRONGHOLD, 0.55)
		if n == 15:
			return lerpf(ISLAND_RADIUS_MAX, ISLAND_RADIUS_STRONGHOLD, 0.8)
		return ISLAND_RADIUS_STRONGHOLD
	return lerpf(ISLAND_RADIUS, ISLAND_RADIUS_MAX, level_t(n))


## The fort grows with its isle.
##
## Corner mounts sit on the fort's own corner towers, so a fort that does not
## scale leaves the "ring" of guns as a ~105 px huddle in the middle of a 460 px
## island: four sectors radiating from nearly the same point, some 400 px from
## the shore they are meant to defend. Measured, that made the milestone
## strongholds the *easiest* bastions in the campaign, and it quietly voided the
## rule the whole campaign is built on — four live guns close the ring, three
## leave a usable gap — because the geometry that rule describes only holds when
## the mounts are spread across their island.
##
## Scaling by island radius keeps the fort at the fraction of its isle that
## bastion 1 uses (~45%), which is the proportion every sector constant was
## tuned against in the first place.
func fort_scale_for_radius(radius: float) -> float:
	return clampf(radius / ISLAND_RADIUS, 1.0, FORT_SCALE_MAX)


func fort_scale_for_level(level: int) -> float:
	return fort_scale_for_radius(island_radius_for_level(level))


func keep_radius_for_level(level: int) -> float:
	return KEEP_RADIUS * fort_scale_for_level(level)


func fort_clear_radius_for_level(level: int) -> float:
	return FORT_CLEAR_RADIUS * fort_scale_for_level(level)


func keep_hp_for_level(level: int) -> int:
	return KEEP_MAX_HP + (clampi(level, 1, LEVEL_COUNT) - 1) * KEEP_HP_PER_LEVEL


func interceptors_for_level(level: int) -> int:
	var n := clampi(level, 1, LEVEL_COUNT)
	if n < INTERCEPTOR_UNLOCK_LEVEL or n > INTERCEPTOR_MAX_LEVEL:
		return 0
	# Never on a wing's first bastion. Those levels exist to let the player
	# learn a new airframe, and the campaign already forgives a fixed bearing
	# there for the same reason — dropping fighters on someone the first time
	# they fly carpet bombers teaches nothing.
	if n == wing_band_start(plane_type_for_level(n)):
		return 0
	return INTERCEPTOR_MAX_ALIVE


func turret_count_for_level(level: int) -> int:
	# L1–2 teach the loop with 2 guns; L3+ demands a third so blitz stops free-winning.
	var n := clampi(level, 1, LEVEL_COUNT)
	if n <= 2:
		return 2
	if n <= 9:
		return 3
	if is_stronghold_level(n):
		return 4
	if n <= 14:
		return 3
	return 4


func tower_count_range_for_level(level: int) -> Vector2i:
	# 1 early → denser late; milestone bastions pack a thick outer ring.
	# L10 is still a bomber-overfly siege — keep the ring fat, not impossible.
	var n := clampi(level, 1, LEVEL_COUNT)
	if is_stronghold_level(n):
		# Milestone rings are thick, but not so thick that the corridor closes
		# entirely — a carpet wing still has to fly the whole fort to deliver.
		# Bastion 10 is the first stronghold and the fast bomber wing punches
		# through a thin ring whatever direction it comes from; 15 flies the
		# fragile strike wing and was drowning in guns.
		if n == 10:
			# Thickened from (5, 6) so the bomber stronghold answers a fixed
			# bearing at all. (7, 8) was tried and, stacked with the stronghold
			# reach bonus, tipped the level to unwinnable — adaptive play spent
			# the whole wing and left the keep on 23.
			return Vector2i(6, 7)
		if n == 15:
			return Vector2i(4, 5)
		return Vector2i(6, 7)
	# One addition at a time through the opening bastions: L3 brings a third
	# corner gun, L4 the first missile launcher, L5 the faster gun cycle.
	if n <= 3:
		return Vector2i(1, 1)
	if n <= 5:
		return Vector2i(2, 2)
	# The bomber bastions used to thin out here: three corner guns and a couple
	# of towers on a mid-sized island left so much slack that nothing the player
	# did with placement showed up in the result.
	if n <= 9:
		return Vector2i(3, 4)
	if n >= 16:
		return Vector2i(4, 6)
	if n >= FLAK_TOWER_UNLOCK_LEVEL:
		return Vector2i(3, 5)
	var t := level_t(level)
	var lo := clampi(1 + int(floor(t * 3.0)), 1, 4)
	var hi := clampi(2 + int(floor(t * 4.0)), lo, 6)
	return Vector2i(lo, hi)


func turret_range_for_level(level: int) -> float:
	var n := clampi(level, 1, LEVEL_COUNT)
	var base := TURRET_RANGE_HOT if n >= 3 else TURRET_RANGE
	var reach := clampf(island_radius_for_level(n) + TURRET_WATER_REACH, base, TURRET_RANGE_CAP)
	if is_stronghold_level(n):
		reach += TURRET_STRONGHOLD_REACH
	return reach


func turret_cooldown_for_level(level: int) -> float:
	var n := clampi(level, 1, LEVEL_COUNT)
	return TURRET_FIRE_COOLDOWN_HOT if n >= TURRET_COOLDOWN_HOT_LEVEL else TURRET_FIRE_COOLDOWN


## Where a decoy settles into its orbit, for the given island and gun reach.
func decoy_orbit_radius(island_radius: float, gun_range: float) -> float:
	return maxf(gun_range * DECOY_ORBIT_FRACTION, island_radius + DECOY_ORBIT_MIN_MARGIN)


## Rough keep punch per bird — used for star thresholds across wing types.
func expected_keep_damage_per_plane(plane_type: PlaneType) -> int:
	match plane_type:
		PlaneType.GUNSHIP:
			# Most shots go into AA; expect ~half the payload on the keep.
			return GUNSHIP_SHOT_COUNT * GUNSHIP_SHOT_DAMAGE / 2
		PlaneType.STRIKE:
			return STRIKE_MISSILE_DAMAGE
		PlaneType.CARPET:
			# Stick centered on the keep — expect ~2 of 3 on target.
			return CARPET_BOMB_DAMAGE * 2
		_:
			return KEEP_BOMB_DAMAGE


func three_star_max_used(
	_keep_max_hp: int, _gun_count: int, squadron: int, _level: int = 1
) -> int:
	return maxi(int(floor(float(squadron) * THREE_STAR_FRACTION)), 1)


func stars_for_win(
	planes_used: int, keep_max_hp: int, gun_count: int, squadron: int, level: int = 1
) -> int:
	if planes_used <= three_star_max_used(keep_max_hp, gun_count, squadron, level):
		return 3
	if planes_used <= int(floor(float(squadron) * TWO_STAR_FRACTION)):
		return 2
	return 1
