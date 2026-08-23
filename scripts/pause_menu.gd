extends CanvasLayer

## Pause and options, on its own always-processing layer.
##
## A desktop player expects Esc to stop the world, and a Steam Deck player
## expects Start to do the same with a focused control already under the
## D-pad. Both go through here. The panel is built in code rather than in a
## scene because every row is a settings binding — keeping the widget and the
## Settings call in the same place is what stops the two drifting apart.

signal opened
signal closed

const PANEL_WIDTH := 520.0
const ROW_HEIGHT := 44.0

enum Page { ROOT, OPTIONS }

var _main: Node2D
var _page: Page = Page.ROOT
var _was_paused_by_us := false

var _dim: ColorRect
var _panel: PanelContainer
var _body: VBoxContainer
var _title: Label
var _root_page: VBoxContainer
var _options_page: VBoxContainer
var _first_focus: Control
var _options_first_focus: Control

var _quit_confirm := false
var _quit_button: Button
## Re-read hooks, one per options row. The page is built once, but Settings can
## move underneath it — F11, M, or another session's saved file — so every row
## has to be able to pull its current value back out rather than trusting the
## snapshot it was constructed with. Without this the first click on a stale
## toggle sends the value already in effect, which no-ops, and the control reads
## as broken until you click it twice.
var _refreshers: Array[Callable] = []


func _ready() -> void:
	layer = 40
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_build()


func setup(main_ref: Node2D) -> void:
	_main = main_ref


func is_open() -> bool:
	return visible


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func open() -> void:
	if visible:
		return
	refresh_options()
	_show_page(Page.ROOT)
	visible = true
	# Only claim the pause flag if something else has not already set it —
	# otherwise closing the menu would resume a game that was paused for
	# another reason.
	_was_paused_by_us = not get_tree().paused
	get_tree().paused = true
	if _first_focus:
		_first_focus.grab_focus()
	opened.emit()


func close() -> void:
	if not visible:
		return
	visible = false
	if _was_paused_by_us:
		get_tree().paused = false
	_was_paused_by_us = false
	_reset_quit_confirm()
	closed.emit()


## Playtest / debug hook: open straight onto the options page.
func show_options() -> void:
	if not visible:
		open()
	refresh_options()
	_show_page(Page.OPTIONS)


func refresh_options() -> void:
	for r in _refreshers:
		r.call()


func _unhandled_input(event: InputEvent) -> void:
	# These live here rather than in main.gd because this layer is
	# PROCESS_MODE_ALWAYS: handled in the pausable level scene, they silently
	# stopped working exactly while the pause menu was open, which is the moment
	# a player is most likely to reach for them.
	if event.is_action_pressed("toggle_fullscreen"):
		Settings.toggle_fullscreen()
		refresh_options()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("toggle_mute"):
		Settings.toggle_muted()
		refresh_options()
		get_viewport().set_input_as_handled()
		return

	if event.is_action_pressed("pause"):
		if visible and _page == Page.OPTIONS:
			_show_page(Page.ROOT)
		else:
			toggle()
		get_viewport().set_input_as_handled()
	elif visible and event.is_action_pressed("ui_cancel"):
		if _page == Page.OPTIONS:
			_show_page(Page.ROOT)
		else:
			close()
		get_viewport().set_input_as_handled()


## --- construction --------------------------------------------------------


func _build() -> void:
	_dim = ColorRect.new()
	_dim.color = Color(0.03, 0.05, 0.08, 0.72)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", _panel_style())
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(_panel)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 14)
	_panel.add_child(_body)

	_title = _make_label("PAUSED", 34, Color(0.98, 0.95, 0.85))
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_body.add_child(_title)

	_root_page = _build_root_page()
	_body.add_child(_root_page)

	_options_page = _build_options_page()
	_body.add_child(_options_page)


func _build_root_page() -> VBoxContainer:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)

	var resume := _make_button("RESUME")
	resume.pressed.connect(close)
	page.add_child(resume)
	_first_focus = resume

	var restart := _make_button("RESTART BASTION")
	restart.pressed.connect(_on_restart_level)
	page.add_child(restart)

	var options := _make_button("OPTIONS")
	options.pressed.connect(_show_page.bind(Page.OPTIONS))
	page.add_child(options)

	_quit_button = _make_button("QUIT GAME")
	_quit_button.pressed.connect(_on_quit)
	page.add_child(_quit_button)

	var hint := _make_label(
		"Esc pause · Space scramble · WASD aim · F11 fullscreen", 15, Color(0.85, 0.9, 0.86, 0.6)
	)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(hint)
	return page


func _build_options_page() -> VBoxContainer:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)
	page.visible = false

	page.add_child(_section_label("AUDIO"))
	_options_first_focus = _add_slider(
		page,
		"Master",
		func() -> float: return Settings.master_volume,
		Settings.set_master_volume
	)
	_add_slider(
		page, "Effects", func() -> float: return Settings.sfx_volume, Settings.set_sfx_volume
	)
	_add_slider(
		page, "Music", func() -> float: return Settings.music_volume, Settings.set_music_volume
	)
	_add_slider(
		page,
		"Ambience",
		func() -> float: return Settings.ambience_volume,
		Settings.set_ambience_volume
	)
	_add_check(page, "Mute all", func() -> bool: return Settings.muted, Settings.set_muted)

	# Web refuses a fullscreen request made outside a user gesture and has no
	# v-sync control at all; phones are always fullscreen. Offering dead
	# switches is worse than offering none.
	if Settings.can_manage_window():
		page.add_child(_section_label("VIDEO"))
		_add_check(
			page, "Fullscreen", func() -> bool: return Settings.fullscreen, Settings.set_fullscreen
		)
		_add_check(page, "V-Sync", func() -> bool: return Settings.vsync, Settings.set_vsync)

	page.add_child(_section_label("ACCESSIBILITY"))
	_add_slider(
		page,
		"Screen shake",
		func() -> float: return Settings.screen_shake,
		Settings.set_screen_shake
	)
	_add_check(
		page,
		"Reduced motion",
		func() -> bool: return Settings.reduced_motion,
		Settings.set_reduced_motion
	)
	_add_option(
		page,
		"Colourblind",
		Settings.COLORBLIND_NAMES,
		func() -> int: return int(Settings.colorblind_mode),
		Settings.set_colorblind_mode
	)

	var back := _make_button("BACK")
	back.pressed.connect(_show_page.bind(Page.ROOT))
	page.add_child(back)
	return page


func _show_page(page: Page) -> void:
	_page = page
	_reset_quit_confirm()
	_root_page.visible = page == Page.ROOT
	_options_page.visible = page == Page.OPTIONS
	_title.text = "PAUSED" if page == Page.ROOT else "OPTIONS"
	var focus := _first_focus if page == Page.ROOT else _options_first_focus
	if focus and visible:
		focus.grab_focus()


## --- rows ----------------------------------------------------------------


func _add_slider(parent: Node, label: String, getter: Callable, setter: Callable) -> Control:
	var row := _make_row(label)
	var value: float = getter.call()
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.05
	slider.value = value
	slider.custom_minimum_size = Vector2(220, ROW_HEIGHT * 0.5)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var readout := _make_label("%d%%" % roundi(value * 100.0), 16, Color(0.9, 0.93, 0.88, 0.8))
	readout.custom_minimum_size = Vector2(52, 0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	slider.value_changed.connect(
		func(v: float) -> void:
			setter.call(v)
			readout.text = "%d%%" % roundi(v * 100.0)
	)
	row.add_child(slider)
	row.add_child(readout)
	parent.add_child(row)
	_refreshers.append(
		func() -> void:
			var v: float = getter.call()
			slider.set_value_no_signal(v)
			readout.text = "%d%%" % roundi(v * 100.0)
	)
	return slider


func _add_check(parent: Node, label: String, getter: Callable, setter: Callable) -> Control:
	var row := _make_row(label)
	var check := CheckButton.new()
	check.button_pressed = bool(getter.call())
	check.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	check.toggled.connect(func(on: bool) -> void: setter.call(on))
	row.add_child(check)
	parent.add_child(row)
	_refreshers.append(
		func() -> void: check.set_pressed_no_signal(bool(getter.call()))
	)
	return check


func _add_option(
	parent: Node, label: String, choices: Array, getter: Callable, setter: Callable
) -> Control:
	var row := _make_row(label)
	var box := OptionButton.new()
	for i in choices.size():
		box.add_item(str(choices[i]), i)
	box.selected = clampi(int(getter.call()), 0, maxi(choices.size() - 1, 0))
	box.custom_minimum_size = Vector2(200, ROW_HEIGHT * 0.8)
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	box.item_selected.connect(func(i: int) -> void: setter.call(i))
	row.add_child(box)
	parent.add_child(row)
	_refreshers.append(
		func() -> void: box.selected = clampi(int(getter.call()), 0, maxi(choices.size() - 1, 0))
	)
	return box


func _make_row(label: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.custom_minimum_size = Vector2(0, ROW_HEIGHT)
	var name_label := _make_label(label, 19, Color(0.94, 0.95, 0.9))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_label)
	return row


func _section_label(text: String) -> Label:
	var l := _make_label(text, 15, Color(0.95, 0.82, 0.35, 0.9))
	l.custom_minimum_size = Vector2(0, 30)
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	return l


func _make_label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _make_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 52)
	b.add_theme_font_size_override("font_size", 21)
	b.add_theme_stylebox_override("normal", _button_style(Color(0.95, 0.82, 0.35)))
	b.add_theme_stylebox_override("hover", _button_style(Color(1.0, 0.88, 0.42)))
	b.add_theme_stylebox_override("pressed", _button_style(Color(0.88, 0.74, 0.3)))
	b.add_theme_stylebox_override("focus", _button_style(Color(1.0, 0.93, 0.6)))
	b.add_theme_color_override("font_color", Color(0.14, 0.1, 0.04))
	b.add_theme_color_override("font_hover_color", Color(0.12, 0.08, 0.03))
	b.add_theme_color_override("font_pressed_color", Color(0.12, 0.08, 0.03))
	b.add_theme_color_override("font_focus_color", Color(0.12, 0.08, 0.03))
	return b


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.07, 0.04, 0.96)
	sb.border_color = Color(0.95, 0.78, 0.35, 0.55)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(16)
	sb.content_margin_left = 32
	sb.content_margin_right = 32
	sb.content_margin_top = 26
	sb.content_margin_bottom = 26
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 18
	sb.shadow_offset = Vector2(0, 8)
	return sb


func _button_style(bg: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


## --- actions -------------------------------------------------------------


func _on_restart_level() -> void:
	close()
	if _main and _main.has_method("retry_level"):
		_main.retry_level()


## Two-step, because a stray Start-button press on a controller should not end
## someone's run.
func _on_quit() -> void:
	if not _quit_confirm:
		_quit_confirm = true
		_quit_button.text = "QUIT — PRESS AGAIN"
		return
	get_tree().quit()


func _reset_quit_confirm() -> void:
	_quit_confirm = false
	if _quit_button:
		_quit_button.text = "QUIT GAME"
