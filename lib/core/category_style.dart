import 'package:flutter/material.dart';
import 'package:juno/core/ui/tokens.dart';

/// Icon keys stored on categories. Kept as an explicit const map so icon
/// tree-shaking still works (no IconData built from ints at runtime).
const categoryIcons = <String, IconData>{
  'cart': Icons.shopping_cart_outlined,
  'dining': Icons.restaurant_outlined,
  'coffee': Icons.coffee_outlined,
  'car': Icons.directions_car_outlined,
  'fuel': Icons.local_gas_station_outlined,
  'home': Icons.home_outlined,
  'bolt': Icons.bolt_outlined,
  'wifi': Icons.wifi_outlined,
  'repeat': Icons.autorenew_rounded,
  'bag': Icons.shopping_bag_outlined,
  'health': Icons.favorite_border_rounded,
  'fitness': Icons.fitness_center_outlined,
  'ticket': Icons.confirmation_number_outlined,
  'plane': Icons.flight_outlined,
  'gift': Icons.card_giftcard_outlined,
  'spray': Icons.cleaning_services_outlined,
  'book': Icons.menu_book_outlined,
  'pet': Icons.pets_outlined,
  'baby': Icons.child_friendly_outlined,
  'phone': Icons.smartphone_outlined,
  'tools': Icons.handyman_outlined,
  'beauty': Icons.spa_outlined,
  'bank': Icons.account_balance_outlined,
  'card': Icons.credit_card_outlined,
  'dots': Icons.more_horiz_rounded,
  'briefcase': Icons.work_outline_rounded,
  'laptop': Icons.laptop_mac_outlined,
  'undo': Icons.undo_rounded,
  'plus': Icons.add_rounded,
  'savings': Icons.savings_outlined,
};

IconData categoryIcon(String? key) => categoryIcons[key] ?? Icons.more_horiz_rounded;

/// Categorical series palette — the dataviz reference eight, validated against
/// Juno's own surfaces (light #F6F4F0, dark #1A1414): adjacent CVD ΔE ≥ 8.4,
/// normal-vision ≥ 19.3. Light slots 2–5 sit under 3:1 on paper, so every chart
/// that uses them also prints labels and values (the relief rule).
///
/// Colour belongs to the category (stored index), never to its rank in a
/// chart, so filtering never repaints the survivors.
const _seriesLight = [
  Color(0xFF2A78D6),
  Color(0xFFEB6834),
  Color(0xFF1BAF7A),
  Color(0xFFEDA100),
  Color(0xFFE87BA4),
  Color(0xFF008300),
  Color(0xFF4A3AA7),
  Color(0xFFE34948),
];

const _seriesDark = [
  Color(0xFF3987E5),
  Color(0xFFD95926),
  Color(0xFF199E70),
  Color(0xFFC98500),
  Color(0xFFD55181),
  Color(0xFF008300),
  Color(0xFF9085E9),
  Color(0xFFE66767),
];

const seriesCount = 8;

Color seriesColor(JColors c, int index) => (c.isDark ? _seriesDark : _seriesLight)[index % seriesCount];

/// The fold-in colour for "Other" — neutral, never a ninth hue.
Color otherColor(JColors c) => c.isDark ? const Color(0xFF5A5250) : const Color(0xFFB9B4AC);
