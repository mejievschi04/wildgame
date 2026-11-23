class_name PrimalIcons
extends RefCounted
## Line icons for the UI, 24×24 SVG bodies. "C" is replaced by the tint; UITheme.icon() rasterises and caches them.
## Drawn for this game: stroke 1.8, round caps, shapes from the stone-age kit (club, bow, flint axe, hide tent).

const SVG := {
	# Menu
	"play": '<path d="M8 5.2v13.6l10.6-6.8z" fill="C"/>',
	"tent": '<path d="M3 20.5L12 5l9 15.5z"/><path d="M12 5v15.5M9.6 20.5l2.4-5.2 2.4 5.2M10 3l2 2 2-2"/>',
	"load": '<rect x="5" y="3" width="14" height="18" rx="2.5"/><path d="M8.5 8h7M8.5 12h7M8.5 16h4.5"/>',
	"settings": '<path d="M4 7h9M18 7h2M4 17h3M12 17h8"/><circle cx="15.5" cy="7" r="2.3"/><circle cx="9.5" cy="17" r="2.3"/>',
	"hand": '<path d="M7.5 12.5V7.2a1.5 1.5 0 0 1 3 0v4.6M10.5 11V5a1.5 1.5 0 0 1 3 0v6M13.5 11.2V6.2a1.5 1.5 0 0 1 3 0v5.6M16.5 12V9.4a1.5 1.5 0 0 1 3 0v4.8c0 4-2.8 6.8-6.6 6.8-2.4 0-4.2-1.1-5.4-3L4.7 14a1.5 1.5 0 0 1 2.4-1.7z"/>',
	"tribe": '<circle cx="9" cy="8" r="3"/><path d="M3.5 20c.5-3.6 2.6-5.6 5.5-5.6s5 2 5.5 5.6"/><circle cx="17" cy="9" r="2.4"/><path d="M15.6 14.3c.5-.2.9-.3 1.4-.3 2.3 0 3.9 1.6 4.3 4.6"/>',
	"power": '<path d="M12 3v8.5"/><path d="M7.2 6.4a7.4 7.4 0 1 0 9.6 0"/>',
	"credits": '<path d="M12 3.5l2.5 5.2 5.7.8-4.1 4 1 5.7-5.1-2.7-5.1 2.7 1-5.7-4.1-4 5.7-.8z"/>',
	# Inventory tabs
	"bag": '<path d="M9 8C9 5.4 10.3 3.6 12 3.6S15 5.4 15 8"/><path d="M6.4 8.6h11.2l1.6 11.3a1 1 0 0 1-1 1.1H5.8a1 1 0 0 1-1-1.1z"/><path d="M9.4 12.8h5.2"/>',
	"skills": '<circle cx="12" cy="4.8" r="2.1"/><path d="M12 7.4v8.2M6.5 10.5l5.5 2 5.5-2M8.5 21l3.5-5.4 3.5 5.4"/>',
	"book": '<path d="M3 5.6c3-1.1 6-1 9 1 3-2 6-2.1 9-1V19c-3-1-6-.9-9 1-3-1.9-6-2-9-1z"/><path d="M12 6.6V20"/>',
	"map": '<path d="M3.5 6.5l5.5-2 6 2 5.5-2v13l-5.5 2-6-2-5.5 2z"/><path d="M9 4.5v13M15 6.5v13"/>',
	# Craft groups
	"arms": '<path d="M5 20l7-7"/><path d="M10.6 10.6c.6-3.7 3.8-6.8 7.4-6.7.8 3.4-2.6 7-6.6 7.6z" fill="C"/>',
	"ranged": '<path d="M7 3c6.8 3.3 9.4 10.4 5.2 18"/><path d="M7 3l5.2 18" stroke-width="1"/><path d="M3.5 12.6h15M16 10l2.6 2.6L16 15.2"/>',
	"tools": '<path d="M6.5 21L15.5 6"/><path d="M12.6 4.4l5.8 3.1c.9 2.7-.6 5.2-3.2 5.6L10.9 10z" fill="C"/>',
	"materials": '<path d="M5 19.5C5 10.5 10 5 20 4c0 9.2-5.2 15.5-13.2 15.5z"/><path d="M5 19.5l9.2-9.2"/>',
	"shelter": '<path d="M3 20.5L12 5l9 15.5z"/><path d="M12 5v15.5M9.6 20.5l2.4-5.2 2.4 5.2"/>',
	"fire": '<path d="M12 2.8c.8 3 4.6 5 4.6 9.8a4.6 4.6 0 0 1-9.2 0c0-2.4 1.4-3.6 2-5.2.9 1 1.3 2 2.3 2.3.8-2.3-.2-4.6.3-6.9z" fill="C"/><path d="M5 21.2l14-3M19 21.2l-14-3"/>',
	"food": '<path d="M14.5 4.4c3 0 5.1 2.1 5.1 5 0 4-4.6 7.1-8.6 7.1-.9 0-1.7-.2-2.4-.6l-2.5 2.5a1.6 1.6 0 1 1-2.3 1.4 1.6 1.6 0 1 1 1.4-2.4l2.6-2.4c-.4-.7-.6-1.4-.6-2.2 0-4.2 3.6-8.4 7.3-8.4z" fill="C"/>',
	"other": '<circle cx="6" cy="12" r="1.6" fill="C"/><circle cx="12" cy="12" r="1.6" fill="C"/><circle cx="18" cy="12" r="1.6" fill="C"/>',
	"dots": '<circle cx="6" cy="12" r="1.6" fill="C"/><circle cx="12" cy="12" r="1.6" fill="C"/><circle cx="18" cy="12" r="1.6" fill="C"/>',
	# Item card stats and vitals
	"damage": '<path d="M4 20l9.5-9.5"/><path d="M12.6 6.6L20 4l-2.6 7.4-3.4.4-2-2z" fill="C"/>',
	"durability": '<path d="M12 3l7 3v5.2c0 4.8-3 8.4-7 9.8-4-1.4-7-5-7-9.8V6z"/>',
	"weight": '<path d="M7.6 8.5h8.8l3.1 11.5H4.5z"/><circle cx="12" cy="5.6" r="2.1"/>',
	"health": '<path d="M9.6 4h4.8v5.6H20v4.8h-5.6V20H9.6v-5.6H4V9.6h5.6z" fill="C"/>',
	"stamina": '<circle cx="15" cy="4.4" r="2.1" fill="C"/><path d="M5.5 11.2l4-3.4 4.2 1.4 2 4 3 1.2M9.5 7.8l-2 6.2 4 2.5-1 5M7.5 14l-3.4 5.5"/>',
	"hunger": '<path d="M14.5 4.4c3 0 5.1 2.1 5.1 5 0 4-4.6 7.1-8.6 7.1-.9 0-1.7-.2-2.4-.6l-2.5 2.5a1.6 1.6 0 1 1-2.3 1.4 1.6 1.6 0 1 1 1.4-2.4l2.6-2.4c-.4-.7-.6-1.4-.6-2.2 0-4.2 3.6-8.4 7.3-8.4z" fill="C"/>',
	"thirst": '<path d="M12 3c3 4.5 6 7.6 6 11a6 6 0 0 1-12 0c0-3.4 3-6.5 6-11z" fill="C"/>',
	"lock": '<rect x="5" y="10.5" width="14" height="10" rx="2" fill="C"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5"/>',
	"tip": '<path d="M4 20L20 4M4 4l16 16"/><path d="M16.4 3.6h4v4M7.6 3.6h-4v4"/>',
	# Input glyphs
	"mouse_l": '<rect x="6" y="3" width="12" height="18" rx="6"/><path d="M12 3v7.5M6 10.5h12"/><path d="M12 3.3a5.7 5.7 0 0 0-5.7 5.7v1.5H12z" fill="C"/>',
	"mouse_r": '<rect x="6" y="3" width="12" height="18" rx="6"/><path d="M12 3v7.5M6 10.5h12"/><path d="M12 3.3a5.7 5.7 0 0 1 5.7 5.7v1.5H12z" fill="C"/>',
	"chev_l": '<path d="M14.5 5.5L8 12l6.5 6.5"/>',
	"chev_r": '<path d="M9.5 5.5L16 12l-6.5 6.5"/>',
}
