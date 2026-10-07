-- Data on Tap — seed data
-- Run after schema.sql. Idempotent-ish: assumes fresh tables (schema.sql drops/recreates).

-- Branches: 6 total, 2 per city (Stockholm, Goteborg, Malmo). lat/long left NULL for now.
INSERT INTO branches (branch_name, city, address, latitude, longitude) VALUES
    ('Data on Tap Sodermalm',     'Stockholm', 'Gotgatan 12, Stockholm',        59.376065, 17.937925),
    ('Data on Tap Ostermalm',     'Stockholm', 'Sturegatan 4, Stockholm',       59.337600, 18.084600),
    ('Data on Tap Centrum',       'Goteborg',  'Kungsgatan 20, Goteborg',       57.707500, 11.967500),
    ('Data on Tap Majorna',       'Goteborg',  'Karl Johansgatan 40, Goteborg', 57.696000, 11.920000),
    ('Data on Tap Centrum',       'Malmo',     'Sodergatan 15, Malmo',          55.605000, 13.000000),
    ('Data on Tap Vastra Hamnen', 'Malmo',     'Isbergs gata 3, Malmo',         55.615000, 12.977000);

-- Menu: 6 pizzas, brand-wide catalog. description + ingredients feed the pizza detail page.
INSERT INTO menu (pizza_name, price, diet_type, description, ingredients) VALUES
    ('Margherita',     159.00, 'veg',
     'The timeless classic — a thin, blistered base that lets three good ingredients do the talking.',
     'San Marzano tomato sauce, fresh mozzarella, basil, extra-virgin olive oil'),
    ('Four Cheese',    189.00, 'veg',
     'A rich quattro formaggi for the cheese devoted, balanced by a light tomato base.',
     'Tomato sauce, mozzarella, gorgonzola, parmesan, provolone'),
    ('Veggie Supreme', 199.00, 'veg',
     'A loaded garden pie with a bit of everything — colourful, crunchy and satisfying.',
     'Tomato sauce, mozzarella, bell peppers, red onion, mushrooms, black olives, sweetcorn'),
    ('Vegan Garden',   209.00, 'vegan',
     'Fully plant-based and proud of it, finished with peppery rocket after the bake.',
     'Tomato sauce, vegan mozzarella, cherry tomatoes, courgette, rocket, basil'),
    ('Pepperoni',      219.00, 'non-veg',
     'The Friday-night favourite — cups of spicy pepperoni crisped at the edges.',
     'Tomato sauce, mozzarella, spicy pepperoni'),
    ('BBQ Chicken',    249.00, 'non-veg',
     'Smoky barbecue base with grilled chicken and sweet red onion, brightened with coriander.',
     'BBQ sauce, mozzarella, grilled chicken, red onion, coriander');

-- Inventory: every (branch, pizza) pair. Varied stock so low-stock demo has triggers.
-- Cross join gives all 6x6=36 rows; base stock per pizza, then a couple deliberately low.
INSERT INTO inventory (branch_id, menu_id, stock_quantity)
SELECT b.branch_id, m.id,
       CASE m.pizza_name
           WHEN 'Margherita'     THEN 20
           WHEN 'Four Cheese'    THEN 14
           WHEN 'Veggie Supreme' THEN 12
           WHEN 'Vegan Garden'   THEN 6
           WHEN 'Pepperoni'      THEN 15
           WHEN 'BBQ Chicken'    THEN 4
       END
FROM branches b CROSS JOIN menu m;

-- Make one branch's popular items scarce for a clean concurrency/low-stock demo.
UPDATE inventory SET stock_quantity = 3
WHERE branch_id = 1 AND menu_id IN (SELECT id FROM menu WHERE pizza_name = 'Pepperoni');
UPDATE inventory SET stock_quantity = 2
WHERE branch_id = 1 AND menu_id IN (SELECT id FROM menu WHERE pizza_name = 'BBQ Chicken');

-- Customers: a handful of fake people. All seeded accounts share the demo
-- password "pizza" (pbkdf2_sha256 hash below) so you can log in on event day.
INSERT INTO customers (name, email, phone, password_hash) VALUES
    ('Anna Svensson',   'anna@example.se',   '070-1111111', 'pbkdf2_sha256$200000$d8157514a1c513ca4ce9ca56a052417a$71af18ab8e4778f6a60d88a4288c77721722ab20004a30790824e5989f24b985'),
    ('Erik Lindqvist',  'erik@example.se',   '070-2222222', 'pbkdf2_sha256$200000$d8157514a1c513ca4ce9ca56a052417a$71af18ab8e4778f6a60d88a4288c77721722ab20004a30790824e5989f24b985'),
    ('Sara Johansson',  'sara@example.se',   '070-3333333', 'pbkdf2_sha256$200000$d8157514a1c513ca4ce9ca56a052417a$71af18ab8e4778f6a60d88a4288c77721722ab20004a30790824e5989f24b985'),
    ('Johan Berg',      'johan@example.se',  '070-4444444', 'pbkdf2_sha256$200000$d8157514a1c513ca4ce9ca56a052417a$71af18ab8e4778f6a60d88a4288c77721722ab20004a30790824e5989f24b985'),
    ('Lena Nilsson',    'lena@example.se',   '070-5555555', 'pbkdf2_sha256$200000$d8157514a1c513ca4ce9ca56a052417a$71af18ab8e4778f6a60d88a4288c77721722ab20004a30790824e5989f24b985');

-- Sample saved addresses for Anna (looked up by email, since customer_id now
-- starts high and is no longer a hard-coded 1).
INSERT INTO customer_addresses (customer_id, label, street, city, postal_code, latitude, longitude)
SELECT c.customer_id, v.label, v.street, v.city, v.postal_code, v.lat, v.lng
FROM customers c
CROSS JOIN (VALUES
    ('Home', 'Gotgatan 12',  'Stockholm', '118 46', 59.385579::numeric, 17.942471::numeric),
    ('Work', 'Sturegatan 4', 'Stockholm', '114 35', NULL::numeric,       NULL::numeric)
) AS v(label, street, city, postal_code, lat, lng)
WHERE c.email = 'anna@example.se';

-- Staff logins (org-provisioned; no self-signup). Demo password is "kitchen".
-- kitchen.goteborg -> branch 3 (Pizza Hut Centrum, Goteborg); kitchen.sodermalm -> branch 1.
INSERT INTO staff (name, email, password_hash, branch_id) VALUES
    ('Goteborg Kitchen', 'kitchen.goteborg@dataontap.se', 'pbkdf2_sha256$200000$f2ae43958a62ff5026ab237b7df3d835$4d57ea7fdac955632e77efc2bc81d8b85387fc2564797aa267f028d9666d3a41', 3),
    ('Sodermalm Kitchen', 'kitchen.sodermalm@dataontap.se', 'pbkdf2_sha256$200000$f2ae43958a62ff5026ab237b7df3d835$4d57ea7fdac955632e77efc2bc81d8b85387fc2564797aa267f028d9666d3a41', 1);

-- Delivery partners: a few, assigned to branches (event-day assignment logic uses these).
-- email + demo password "partner" for the delivery-partner login.
-- Each partner's location seeded to their branch's coordinates.
INSERT INTO delivery_partners (name, email, password_hash, phone, status, current_branch_id, latitude, longitude) VALUES
    ('Oskar Falk',  'oskar@dataontap.se', 'pbkdf2_sha256$200000$571f66e92708bd26caaa657d6c012430$2e7de6e9f40d8ab5be0370c1737d2d9e8e38399ed96c1a431586cb684c7031f9', '070-6666666', 'available', 1, 59.382510, 17.955957),
    ('Maja Holm',   'maja@dataontap.se',  'pbkdf2_sha256$200000$571f66e92708bd26caaa657d6c012430$2e7de6e9f40d8ab5be0370c1737d2d9e8e38399ed96c1a431586cb684c7031f9', '070-7777777', 'available', 1, 59.313000, 18.076000),
    ('Nils Ek',     'nils@dataontap.se',  'pbkdf2_sha256$200000$571f66e92708bd26caaa657d6c012430$2e7de6e9f40d8ab5be0370c1737d2d9e8e38399ed96c1a431586cb684c7031f9', '070-8888888', 'available', 3, 57.707500, 11.967500),
    ('Freja Lund',  'freja@dataontap.se', 'pbkdf2_sha256$200000$571f66e92708bd26caaa657d6c012430$2e7de6e9f40d8ab5be0370c1737d2d9e8e38399ed96c1a431586cb684c7031f9', '070-9999999', 'available', 5, 55.605000, 13.000000);
