/**
 * Dev-only stub of the ChipHealth API.
 *
 * The backend is written in parallel, so `VITE_USE_MSW=true` installs this
 * `fetch` interceptor and every admin screen runs against in-memory fixtures:
 * real cursor pagination, real `{ error: { code, message, details.issues } }`
 * envelopes, real 403s. Never installed in a production build — main.ts only
 * imports it behind `import.meta.env.DEV`.
 */
import type {
  ActivityType,
  ActivityTypeInput,
  AdminUser,
  BarcodeMiss,
  Food,
  FoodInput,
  FoodSource,
  ImportRowResult,
  KbDocument,
  Translation,
  WorkoutExercise,
} from './types'

const LATENCY_MS = 220
const MOCK_ADMIN_ID = 'u-0000000000000000000001'

/* ------------------------------------------------------------ helpers */

let seq = 0
function id(prefix: string): string {
  seq += 1
  return `${prefix}-${(Date.now() - 1_600_000_000_000).toString(16)}${seq.toString().padStart(4, '0')}`
}

const DAY = 86_400_000
const now = Date.now()

function rand(seedRef: { s: number }): number {
  // deterministic LCG so the fixtures look the same on every reload
  seedRef.s = (seedRef.s * 1664525 + 1013904223) % 4294967296
  return seedRef.s / 4294967296
}
const R = { s: 20260907 }
const pick = <T,>(xs: readonly T[]): T => xs[Math.floor(rand(R) * xs.length)]!
const between = (lo: number, hi: number, dp = 1): number =>
  Number((lo + rand(R) * (hi - lo)).toFixed(dp))

/* ------------------------------------------------------------ fixtures */

const VN_DISHES: [string, string, number][] = [
  ['Phở bò tái', 'noodle', 65],
  ['Bún chả Hà Nội', 'noodle', 128],
  ['Cơm tấm sườn bì chả', 'rice_dish', 168],
  ['Bánh mì thịt nguội', 'bread', 245],
  ['Gỏi cuốn tôm thịt', 'appetizer', 78],
  ['Bún bò Huế', 'noodle', 72],
  ['Cơm gà Hội An', 'rice_dish', 155],
  ['Chả giò rán', 'appetizer', 290],
  ['Canh chua cá lóc', 'soup', 48],
  ['Thịt kho tàu', 'meat', 232],
  ['Rau muống xào tỏi', 'vegetable', 58],
  ['Cá kho tộ', 'fish', 175],
  ['Bánh xèo', 'pancake', 210],
  ['Hủ tiếu Nam Vang', 'noodle', 81],
  ['Xôi gà', 'rice_dish', 198],
  ['Bò lúc lắc', 'meat', 188],
  ['Trứng chiên', 'egg', 196],
  ['Đậu hũ sốt cà', 'vegetable', 112],
  ['Nem nướng Nha Trang', 'meat', 241],
  ['Mì Quảng', 'noodle', 96],
  ['Cháo lòng', 'porridge', 62],
  ['Bánh cuốn', 'rice_dish', 118],
  ['Chè đậu xanh', 'dessert', 142],
  ['Sữa đậu nành', 'beverage', 41],
]

const PACKAGED: [string, string, string, number][] = [
  ['Sữa tươi tiệt trùng có đường', 'Vinamilk', 'beverage', 68],
  ['Mì gói Hảo Hảo tôm chua cay', 'Acecook', 'noodle', 446],
  ['Bánh Choco-Pie', 'Orion', 'snack', 428],
  ['Nước ngọt Coca-Cola', 'Coca-Cola', 'beverage', 42],
  ['Sữa chua có đường', 'Vinamilk', 'dairy', 96],
  ['Cà phê sữa lon', 'Highlands', 'beverage', 78],
  ['Bánh gạo An', 'One One', 'snack', 388],
  ['Nước mắm Nam Ngư 40 độ đạm', 'Masan', 'condiment', 62],
  ['Xúc xích tiệt trùng', 'Vissan', 'meat', 292],
  ['Ngũ cốc dinh dưỡng', 'Nestlé', 'cereal', 401],
]

function makeFood(name: string, category: string, kcal: number, brand: string | null, source: FoodSource, i: number): Food {
  const barcode = source === 'admin_barcode' ? `893${String(1000000 + i * 7919).slice(0, 7)}${i % 10}` : null
  return {
    id: `f-${String(i).padStart(6, '0')}-${(now - i * 3_600_000).toString(36)}`,
    barcode,
    name,
    brand,
    category,
    servingSizeG: pick([100, 100, 100, 150, 200, 250, 330]),
    servingLabel: brand ? pick(['1 gói', '1 lon 330ml', '1 hộp', null]) : pick(['1 tô', '1 đĩa', '1 phần', null]),
    caloriesKcal: kcal,
    proteinG: between(1, 28),
    carbsG: between(2, 62),
    fatG: between(0.5, 24),
    saturatedFatG: between(0, 9),
    fiberG: between(0, 7),
    sugarG: between(0, 28),
    sodiumMg: between(10, 1600, 0),
    cholesterolMg: between(0, 180, 0),
    potassiumMg: between(40, 620, 0),
    calciumMg: between(5, 320, 0),
    ironMg: between(0.1, 6, 2),
    micronutrientsJson: null,
    source,
    sourceUrl: source === 'web_search' ? 'https://www.viendinhduong.vn/bang-thanh-phan' : null,
    isVerified: source === 'admin_barcode' || source === 'admin_manual' ? rand(R) > 0.25 : rand(R) > 0.85,
    embeddingStatus: pick(['indexed', 'indexed', 'indexed', 'pending', 'failed'] as const),
    createdBy: MOCK_ADMIN_ID,
    createdAt: now - i * 3_600_000,
    updatedAt: now - i * 1_800_000,
  }
}

const foods: Food[] = []
{
  let i = 0
  for (const [name, cat, kcal] of VN_DISHES) {
    foods.push(makeFood(name, cat, kcal, null, 'admin_manual', i++))
  }
  for (const [name, brand, cat, kcal] of PACKAGED) {
    foods.push(makeFood(name, cat, kcal, brand, 'admin_barcode', i++))
  }
  // filler so pagination actually pages
  const sources: FoodSource[] = ['rag_matched', 'web_search', 'ai_estimated', 'admin_manual']
  for (let n = 0; n < 96; n++) {
    const base = VN_DISHES[n % VN_DISHES.length]!
    foods.push(
      makeFood(
        `${base[0]} (biến thể ${n + 1})`,
        base[1],
        Math.round(base[2] * (0.7 + rand(R) * 0.7)),
        n % 3 === 0 ? pick(['Vinamilk', 'Masan', 'Acecook', 'Kinh Đô']) : null,
        sources[n % sources.length]!,
        i++,
      ),
    )
  }
  foods.sort((a, b) => (a.id < b.id ? 1 : -1))
}

const MISS_HINTS = [
  'Sữa hạt óc chó Hàn Quốc',
  'Bánh quy yến mạch nhập khẩu',
  null,
  'Nước ép ổi ép lạnh',
  'Thanh protein vị socola',
  null,
  'Snack rong biển',
  'Mì trộn Hàn Quốc cay',
]

const barcodeMisses: BarcodeMiss[] = Array.from({ length: 34 }, (_, n) => {
  const status = n < 22 ? 'pending' : n < 29 ? 'resolved' : 'rejected'
  const scanCount = Math.max(1, Math.round((34 - n) * (1 + rand(R) * 4)))
  return {
    id: `bm-${String(n).padStart(4, '0')}-${(now - n * 7_200_000).toString(36)}`,
    barcode: `88${String(10000000 + n * 104729)}`.slice(0, 13),
    scanCount,
    firstScannedBy: `u-${String(n % 12).padStart(6, '0')}`,
    productNameHint: MISS_HINTS[n % MISS_HINTS.length] ?? null,
    photoAssetId: n % 3 === 0 ? `ma-${n}` : null,
    photoUrl:
      n % 3 === 0
        ? `data:image/svg+xml;utf8,${encodeURIComponent(
            `<svg xmlns="http://www.w3.org/2000/svg" width="240" height="320"><rect width="240" height="320" fill="#ede7d9"/><rect x="12" y="12" width="216" height="296" fill="none" stroke="#1b1917" stroke-width="4"/><text x="120" y="150" font-family="monospace" font-size="15" text-anchor="middle" fill="#1b1917">packaging photo</text><text x="120" y="176" font-family="monospace" font-size="13" text-anchor="middle" fill="#c8452b">${n}</text></svg>`,
          )}`
        : null,
    status: status as BarcodeMiss['status'],
    resolvedFoodId: status === 'resolved' ? foods[n % foods.length]!.id : null,
    resolvedBy: status === 'pending' ? null : MOCK_ADMIN_ID,
    resolvedAt: status === 'pending' ? null : now - n * 3_600_000,
    adminNote: status === 'rejected' ? 'Không phải sản phẩm thực phẩm.' : null,
    firstScannedAt: now - (40 - n) * DAY,
    lastScannedAt: now - n * 3_600_000,
  }
}).sort((a, b) => b.scanCount - a.scanCount)

const KB_SEED: [string, string][] = [
  ['Phở bò — thành phần và khẩu phần chuẩn', 'Một tô phở bò tái cỡ vừa (~500 g) gồm khoảng 180 g bánh phở đã trụng, 60 g thịt bò tái, 350 ml nước dùng xương. Nước dùng đóng góp phần lớn natri (700–1100 mg/tô). Hành lá, rau thơm không đáng kể về năng lượng.'],
  ['Quy ước khẩu phần món cơm Việt Nam', 'Một chén cơm trắng đầy tương đương 150–160 g cơm chín (~200 kcal). "Một đĩa cơm tấm" trong hàng quán thường là 250–300 g cơm cộng đồ ăn kèm. Khi người dùng nói "một chén", quy đổi 150 g.'],
  ['Bún chả Hà Nội', 'Suất bún chả gồm ~200 g bún tươi, 90 g chả nướng (thịt ba chỉ + chả viên), 150 ml nước chấm pha loãng. Nước chấm chứa đường nên đóng góp 8–14 g đường mỗi suất.'],
  ['Dầu mỡ trong món xào', 'Món rau xào tại nhà ở Việt Nam dùng trung bình 8–12 g dầu cho 2 phần ăn. Khi ước lượng từ ảnh, cộng thêm 45–70 kcal cho mỗi phần rau xào so với rau luộc.'],
  ['Đồ uống đường phố', 'Trà sữa trân châu cỡ M (500 ml) chứa 40–55 g đường và 280–380 kcal. Cà phê sữa đá vỉa hè (~120 ml) chứa 15–20 g sữa đặc, khoảng 110 kcal.'],
  ['Bảng thành phần — thịt heo', 'Thịt heo ba chỉ sống: 518 kcal/100 g, 53 g mỡ. Nạc vai: 242 kcal/100 g. Sau khi kho, khối lượng giảm ~25% nhưng năng lượng trên 100 g tăng.'],
  ['Nước mắm và natri', 'Một muỗng canh nước mắm (15 ml) chứa khoảng 1400–1600 mg natri. Đây thường là nguồn natri lớn nhất trong bữa ăn Việt.'],
  ['Bánh mì', 'Ổ bánh mì không (~80 g) là 230 kcal. Bánh mì thịt đầy đủ (pate, chả, thịt nguội, bơ, rau) ở mức 400–560 kcal tuỳ lượng bơ và pate.'],
  ['Hải sản phổ biến', 'Tôm sú luộc: 99 kcal/100 g, 24 g đạm, 189 mg cholesterol. Mực hấp: 92 kcal/100 g. Cá lóc: 97 kcal/100 g.'],
  ['Quy ước "một phần" cho món lẩu', 'Khi ghi nhận lẩu, tách thành nước lẩu (ít calo, nhiều natri) và các nguyên liệu nhúng. Một phần lẩu cá 1 người ≈ 320 g nguyên liệu + 400 ml nước.'],
  ['Trái cây nhiệt đới', 'Xoài chín 60 kcal/100 g; sầu riêng 147 kcal/100 g (rất giàu chất béo); mít 95 kcal/100 g; thanh long 50 kcal/100 g.'],
  ['Chè và tráng miệng', 'Một ly chè đậu xanh nước cốt dừa (200 g) khoảng 285 kcal, trong đó 30 g đường và 9 g chất béo từ nước cốt dừa.'],
]

const kbDocuments: KbDocument[] = KB_SEED.concat(
  Array.from({ length: 14 }, (_, n) => [
    `Ghi chú khẩu phần bổ sung #${n + 1}`,
    `Chuẩn hoá khẩu phần cho nhóm món số ${n + 1}. Dùng khi mô hình thị giác trả về mô tả mơ hồ như "một ít", "vừa phải". Quy đổi: một ít = 40 g, vừa phải = 90 g, nhiều = 160 g.`,
  ] as [string, string]),
).map(([title, content], n) => ({
  id: `kb-${String(n).padStart(4, '0')}-${(now - n * 5_400_000).toString(36)}`,
  title,
  content,
  foodId: n < 6 ? foods[n]!.id : null,
  locale: n % 7 === 6 ? 'en' : 'vi',
  vectorizeId: n % 5 === 4 ? null : `vec_${n}`,
  embeddingModel: n % 5 === 4 ? null : '@cf/baai/bge-m3',
  embeddingStatus: (n % 5 === 4 ? 'pending' : n % 11 === 3 ? 'failed' : 'indexed') as KbDocument['embeddingStatus'],
  uploadedBy: MOCK_ADMIN_ID,
  isActive: n % 13 !== 5,
  createdAt: now - n * 5_400_000,
  updatedAt: now - n * 2_400_000,
}))

const activityTypes: ActivityType[] = [
  ['running', 'cardio_gps', 9.8, true, false, true, 'run'],
  ['trail_running', 'cardio_gps', 10.5, true, false, true, 'trail'],
  ['cycling', 'cardio_gps', 8.0, true, false, true, 'bike'],
  ['walking', 'cardio_gps', 3.5, true, false, true, 'walk'],
  ['hiking', 'cardio_gps', 6.0, true, false, true, 'hike'],
  ['swimming', 'cardio_indoor', 8.3, false, false, true, 'swim'],
  ['treadmill', 'cardio_indoor', 9.0, false, false, true, 'treadmill'],
  ['rowing', 'cardio_indoor', 7.0, false, false, true, 'row'],
  ['indoor_cycling', 'cardio_indoor', 8.5, false, false, true, 'spin'],
  ['gym_strength', 'strength', 6.0, false, true, true, 'dumbbell'],
  ['calisthenics', 'strength', 5.0, false, true, true, 'bars'],
  ['badminton', 'sport', 5.5, false, false, true, 'shuttle'],
  ['football', 'sport', 7.0, true, false, true, 'ball'],
  ['tennis', 'sport', 7.3, false, false, true, 'tennis'],
  ['basketball', 'sport', 6.5, false, false, true, 'basket'],
  ['table_tennis', 'sport', 4.0, false, false, true, 'pingpong'],
  ['yoga', 'mind_body', 2.5, false, false, false, 'yoga'],
  ['stretching', 'mind_body', 2.3, false, false, false, 'stretch'],
  ['meditation', 'mind_body', 1.3, false, false, false, 'zen'],
  ['other', 'other', 4.0, false, false, true, null],
].map((row, n) => {
  const [code, category, met, gps, sets, hr, icon] = row as [string, ActivityType['category'], number, boolean, boolean, boolean, string | null]
  return {
    id: n + 1,
    code,
    category,
    defaultMet: met,
    supportsGps: gps,
    supportsSets: sets,
    supportsHeartRate: hr,
    iconName: icon,
    sortOrder: (n + 1) * 10,
    isActive: code !== 'meditation',
  }
})

const exercises: WorkoutExercise[] = [
  ['bench_press', 'chest', 'barbell', false],
  ['incline_dumbbell_press', 'chest', 'dumbbell', false],
  ['push_up', 'chest', 'bodyweight', false],
  ['back_squat', 'legs', 'barbell', false],
  ['front_squat', 'legs', 'barbell', false],
  ['romanian_deadlift', 'legs', 'barbell', false],
  ['leg_press', 'legs', 'machine', false],
  ['bulgarian_split_squat', 'legs', 'dumbbell', true],
  ['deadlift', 'back', 'barbell', false],
  ['barbell_row', 'back', 'barbell', false],
  ['pull_up', 'back', 'bodyweight', false],
  ['lat_pulldown', 'back', 'machine', false],
  ['single_arm_row', 'back', 'dumbbell', true],
  ['overhead_press', 'shoulders', 'barbell', false],
  ['lateral_raise', 'shoulders', 'dumbbell', false],
  ['face_pull', 'shoulders', 'cable', false],
  ['barbell_curl', 'arms', 'barbell', false],
  ['hammer_curl', 'arms', 'dumbbell', true],
  ['triceps_pushdown', 'arms', 'cable', false],
  ['skull_crusher', 'arms', 'barbell', false],
  ['plank', 'core', 'bodyweight', false],
  ['hanging_leg_raise', 'core', 'bodyweight', false],
  ['cable_crunch', 'core', 'cable', false],
  ['russian_twist', 'core', 'kettlebell', false],
].map((row, n) => {
  const [code, muscleGroup, equipment, isUnilateral] = row as [string, string, string, boolean]
  return { id: n + 1, code, muscleGroup, equipment, isUnilateral, sortOrder: (n + 1) * 10 }
})

const VN_NAMES = [
  'Nguyễn Minh Anh', 'Trần Quốc Bảo', 'Lê Thị Cẩm', 'Phạm Đức Duy', 'Hoàng Gia Hân',
  'Vũ Khánh Linh', 'Đặng Nhật Minh', 'Bùi Thanh Ngân', 'Đỗ Phương Uyên', 'Ngô Tiến Đạt',
  'Dương Hải Yến', 'Lý Trọng Nghĩa',
]

const users: AdminUser[] = Array.from({ length: 63 }, (_, n) => ({
  id: n === 0 ? MOCK_ADMIN_ID : `u-${String(n).padStart(6, '0')}-${(now - n * DAY).toString(36)}`,
  email: n === 0 ? 'admin@chiphealth.vn' : `${VN_NAMES[n % VN_NAMES.length]!.split(' ').pop()!.toLowerCase()}${n}@example.com`,
  displayName: n === 0 ? 'Mock Admin' : VN_NAMES[n % VN_NAMES.length]!,
  avatarRemoteUrl: null,
  role: n === 0 || n === 4 ? 'admin' : 'user',
  locale: n % 9 === 0 ? 'en' : 'vi',
  timezone: 'Asia/Ho_Chi_Minh',
  createdAt: now - n * DAY,
  deletedAt: n % 29 === 28 ? now - DAY : null,
})).sort((a, b) => (a.id < b.id ? 1 : -1))

const translations: Translation[] = [
  { id: 1, entityType: 'activity_types', entityId: '1', locale: 'vi', field: 'name', value: 'Chạy bộ' },
  { id: 2, entityType: 'activity_types', entityId: '1', locale: 'en', field: 'name', value: 'Running' },
  { id: 3, entityType: 'activity_types', entityId: '3', locale: 'vi', field: 'name', value: 'Đạp xe' },
  { id: 4, entityType: 'activity_types', entityId: '3', locale: 'en', field: 'name', value: 'Cycling' },
  { id: 5, entityType: 'workout_exercises', entityId: '1', locale: 'vi', field: 'name', value: 'Đẩy ngực nằm' },
  { id: 6, entityType: 'workout_exercises', entityId: '1', locale: 'en', field: 'name', value: 'Bench press' },
  { id: 7, entityType: 'activity_types', entityId: '17', locale: 'vi', field: 'name', value: 'Yoga' },
  { id: 8, entityType: 'activity_types', entityId: '17', locale: 'en', field: 'name', value: 'Yoga' },
]
let translationSeq = translations.length

/* -------------------------------------------------------------- engine */

interface Ctx {
  method: string
  path: string
  query: URLSearchParams
  body: any
  authed: boolean
}

class HttpError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public details?: Record<string, unknown>,
  ) {
    super(message)
  }
}

function fail(status: number, code: string, message: string, details?: Record<string, unknown>): never {
  throw new HttpError(status, code, message, details)
}

function validation(issues: { path: (string | number)[]; message: string }[]): never {
  fail(400, 'VALIDATION_ERROR', 'The request body failed validation.', { issues })
}

function paginate<T extends { id: string }>(rows: T[], query: URLSearchParams) {
  const limit = Math.min(Number(query.get('limit') ?? 50) || 50, 200)
  const cursor = query.get('cursor')
  let start = 0
  if (cursor) {
    const at = rows.findIndex((r) => r.id === cursor)
    start = at === -1 ? 0 : at + 1
  }
  const items = rows.slice(start, start + limit)
  const last = items[items.length - 1]
  const nextCursor = last && start + limit < rows.length ? last.id : null
  return { items, nextCursor }
}

function requireFoodPayload(body: any): FoodInput {
  const issues: { path: (string | number)[]; message: string }[] = []
  if (!body || typeof body.name !== 'string' || !body.name.trim()) {
    issues.push({ path: ['name'], message: 'Name is required.' })
  }
  if (typeof body?.caloriesKcal !== 'number' || Number.isNaN(body.caloriesKcal)) {
    issues.push({ path: ['caloriesKcal'], message: 'Calories must be a number.' })
  } else if (body.caloriesKcal < 0) {
    issues.push({ path: ['caloriesKcal'], message: 'Calories cannot be negative.' })
  }
  if (typeof body?.servingSizeG !== 'number' || !(body.servingSizeG > 0)) {
    issues.push({ path: ['servingSizeG'], message: 'Serving size must be greater than 0.' })
  }
  if (typeof body?.barcode === 'string' && body.barcode && !/^\d{8,14}$/.test(body.barcode)) {
    issues.push({ path: ['barcode'], message: 'Barcode must be 8–14 digits (EAN/UPC).' })
  }
  if (issues.length) validation(issues)
  return body as FoodInput
}

function insertFood(input: FoodInput): Food {
  if (input.barcode && foods.some((f) => f.barcode === input.barcode)) {
    fail(409, 'CONFLICT', `Barcode ${input.barcode} already belongs to another food.`)
  }
  const food: Food = {
    id: id('f'),
    barcode: input.barcode || null,
    name: input.name,
    brand: input.brand || null,
    category: input.category || null,
    servingSizeG: input.servingSizeG,
    servingLabel: input.servingLabel || null,
    caloriesKcal: input.caloriesKcal,
    proteinG: input.proteinG ?? null,
    carbsG: input.carbsG ?? null,
    fatG: input.fatG ?? null,
    saturatedFatG: input.saturatedFatG ?? null,
    fiberG: input.fiberG ?? null,
    sugarG: input.sugarG ?? null,
    sodiumMg: input.sodiumMg ?? null,
    cholesterolMg: input.cholesterolMg ?? null,
    potassiumMg: input.potassiumMg ?? null,
    calciumMg: input.calciumMg ?? null,
    ironMg: input.ironMg ?? null,
    micronutrientsJson: input.micronutrientsJson ?? null,
    source: input.barcode ? 'admin_barcode' : 'admin_manual',
    sourceUrl: input.sourceUrl ?? null,
    isVerified: input.isVerified ?? false,
    embeddingStatus: 'pending',
    createdBy: MOCK_ADMIN_ID,
    createdAt: Date.now(),
    updatedAt: Date.now(),
  }
  foods.unshift(food)
  return food
}

function normalise(s: string): string {
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
}

/* ------------------------------------------------------------- routes */

function handle(ctx: Ctx): unknown {
  const { method, path, query, body } = ctx

  /* auth */
  if (method === 'POST' && path === '/v1/auth/google') {
    if (body?.idToken === 'MOCK_NON_ADMIN') {
      // still issues tokens; /v1/admin/* is what returns 403
      return {
        accessToken: 'mock.access.user',
        refreshToken: 'mock.refresh.user',
        expiresAt: Date.now() + 3_600_000,
        user: { ...users[users.length - 1]!, role: 'user', unitSystem: 'metric' },
      }
    }
    return {
      accessToken: 'mock.access.admin',
      refreshToken: 'mock.refresh.admin',
      expiresAt: Date.now() + 3_600_000,
      user: {
        id: MOCK_ADMIN_ID,
        email: 'admin@chiphealth.vn',
        displayName: 'Mock Admin',
        avatarRemoteUrl: null,
        role: 'admin',
        locale: 'vi',
        unitSystem: 'metric',
        timezone: 'Asia/Ho_Chi_Minh',
      },
    }
  }
  if (method === 'POST' && path === '/v1/auth/refresh') {
    if (!body?.refreshToken) fail(401, 'UNAUTHENTICATED', 'Missing refresh token.')
    const isUser = String(body.refreshToken).endsWith('.user')
    return {
      accessToken: isUser ? 'mock.access.user' : 'mock.access.admin',
      refreshToken: body.refreshToken,
      expiresAt: Date.now() + 3_600_000,
    }
  }
  if (method === 'POST' && path === '/v1/auth/logout') return null
  if (method === 'GET' && path === '/v1/me') {
    const isUser = ctx.authed && getMockRole() === 'user'
    return {
      user: {
        id: isUser ? users[users.length - 1]!.id : MOCK_ADMIN_ID,
        email: isUser ? users[users.length - 1]!.email : 'admin@chiphealth.vn',
        displayName: isUser ? users[users.length - 1]!.displayName : 'Mock Admin',
        avatarRemoteUrl: null,
        role: isUser ? 'user' : 'admin',
        locale: 'vi',
        unitSystem: 'metric',
        timezone: 'Asia/Ho_Chi_Minh',
      },
    }
  }

  /* every /v1/admin route is admin-only */
  if (path.startsWith('/v1/admin')) {
    if (getMockRole() !== 'admin') {
      fail(403, 'FORBIDDEN', 'This account is not an administrator.')
    }
  }

  /* stats */
  if (method === 'GET' && path === '/v1/admin/stats') {
    return {
      users: users.filter((u) => !u.deletedAt).length,
      foods: foods.length,
      pendingBarcodeMisses: barcodeMisses.filter((m) => m.status === 'pending').length,
      kbDocuments: kbDocuments.filter((d) => d.isActive).length,
      mealsAnalysedToday: 418,
      aiFailureRate: 0.037,
    }
  }

  /* foods */
  if (method === 'GET' && path === '/v1/admin/foods') {
    const q = normalise(query.get('q') ?? '')
    const source = query.get('source')
    const verified = query.get('verified')
    let rows = foods
    if (q) rows = rows.filter((f) => normalise(`${f.name} ${f.brand ?? ''} ${f.barcode ?? ''}`).includes(q))
    if (source) rows = rows.filter((f) => f.source === source)
    if (verified === 'true') rows = rows.filter((f) => f.isVerified)
    if (verified === 'false') rows = rows.filter((f) => !f.isVerified)
    return paginate(rows, query)
  }
  if (method === 'POST' && path === '/v1/admin/foods') {
    return insertFood(requireFoodPayload(body))
  }
  if (method === 'POST' && path === '/v1/admin/foods/import') {
    return runImport(body)
  }
  const foodMatch = /^\/v1\/admin\/foods\/([^/]+)(\/verify)?$/.exec(path)
  if (foodMatch) {
    const food = foods.find((f) => f.id === decodeURIComponent(foodMatch[1]!))
    if (!food) fail(404, 'NOT_FOUND', 'Food not found.')
    if (foodMatch[2] === '/verify' && method === 'POST') {
      food.isVerified = body?.isVerified ?? !food.isVerified
      food.updatedAt = Date.now()
      return food
    }
    if (method === 'GET') return food
    if (method === 'PATCH') {
      requireFoodPayload({ ...food, ...body })
      Object.assign(food, body)
      food.source = food.barcode ? 'admin_barcode' : food.source
      food.embeddingStatus = 'pending'
      food.updatedAt = Date.now()
      return food
    }
    if (method === 'DELETE') {
      foods.splice(foods.indexOf(food), 1)
      return null
    }
  }

  /* barcode misses */
  if (method === 'GET' && path === '/v1/admin/barcode-misses') {
    const status = query.get('status') ?? 'pending'
    const rows = barcodeMisses
      .filter((m) => m.status === status)
      .sort((a, b) => b.scanCount - a.scanCount || b.lastScannedAt - a.lastScannedAt)
    return paginate(rows, query)
  }
  const missMatch = /^\/v1\/admin\/barcode-misses\/([^/]+)\/(resolve|reject)$/.exec(path)
  if (missMatch && method === 'POST') {
    const miss = barcodeMisses.find((m) => m.id === decodeURIComponent(missMatch[1]!))
    if (!miss) fail(404, 'NOT_FOUND', 'Barcode miss not found.')
    if (miss.status !== 'pending') fail(409, 'CONFLICT', `This code is already ${miss.status}.`)
    if (missMatch[2] === 'resolve') {
      const food = insertFood(requireFoodPayload({ ...body, barcode: body?.barcode || miss.barcode }))
      miss.status = 'resolved'
      miss.resolvedFoodId = food.id
      miss.resolvedBy = MOCK_ADMIN_ID
      miss.resolvedAt = Date.now()
      return { miss, food }
    }
    if (!body?.adminNote || !String(body.adminNote).trim()) {
      validation([{ path: ['adminNote'], message: 'A note is required when rejecting.' }])
    }
    miss.status = 'rejected'
    miss.adminNote = body.adminNote
    miss.resolvedBy = MOCK_ADMIN_ID
    miss.resolvedAt = Date.now()
    return miss
  }

  /* kb documents */
  if (method === 'POST' && path === '/v1/admin/kb-documents/reindex-all') {
    let queued = 0
    for (const doc of kbDocuments) {
      if (doc.isActive) {
        doc.embeddingStatus = 'pending'
        queued += 1
      }
    }
    return { queued }
  }
  if (method === 'GET' && path === '/v1/admin/kb-documents') {
    const q = normalise(query.get('q') ?? '')
    const rows = q
      ? kbDocuments.filter((d) => normalise(`${d.title} ${d.content}`).includes(q))
      : kbDocuments
    return paginate(rows, query)
  }
  if (method === 'POST' && path === '/v1/admin/kb-documents') {
    const issues: { path: (string | number)[]; message: string }[] = []
    if (!body?.title?.trim()) issues.push({ path: ['title'], message: 'Title is required.' })
    if (!body?.content?.trim()) issues.push({ path: ['content'], message: 'Content is required.' })
    if (issues.length) validation(issues)
    const doc: KbDocument = {
      id: id('kb'),
      title: body.title,
      content: body.content,
      foodId: body.foodId || null,
      locale: body.locale || 'vi',
      vectorizeId: null,
      embeddingModel: null,
      embeddingStatus: 'pending',
      uploadedBy: MOCK_ADMIN_ID,
      isActive: body.isActive ?? true,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    }
    kbDocuments.unshift(doc)
    return doc
  }
  const kbMatch = /^\/v1\/admin\/kb-documents\/([^/]+)(\/reindex)?$/.exec(path)
  if (kbMatch) {
    const doc = kbDocuments.find((d) => d.id === decodeURIComponent(kbMatch[1]!))
    if (!doc) fail(404, 'NOT_FOUND', 'Document not found.')
    if (kbMatch[2] === '/reindex' && method === 'POST') {
      doc.embeddingStatus = 'indexed'
      doc.vectorizeId = doc.vectorizeId ?? `vec_${doc.id}`
      doc.embeddingModel = '@cf/baai/bge-m3'
      doc.updatedAt = Date.now()
      return doc
    }
    if (method === 'GET') return doc
    if (method === 'PATCH') {
      if (body?.title !== undefined && !String(body.title).trim()) {
        validation([{ path: ['title'], message: 'Title is required.' }])
      }
      Object.assign(doc, body)
      doc.embeddingStatus = 'pending'
      doc.updatedAt = Date.now()
      return doc
    }
    if (method === 'DELETE') {
      kbDocuments.splice(kbDocuments.indexOf(doc), 1)
      return null
    }
  }

  /* search preview */
  if (method === 'POST' && path === '/v1/admin/search/preview') {
    return searchPreview(String(body?.q ?? ''))
  }

  /* catalogs */
  if (path === '/v1/admin/activity-types') {
    if (method === 'GET') {
      return { items: [...activityTypes].sort((a, b) => a.sortOrder - b.sortOrder), nextCursor: null }
    }
    if (method === 'POST') {
      const input = requireActivityType(body)
      if (activityTypes.some((a) => a.code === input.code)) {
        fail(409, 'CONFLICT', `Activity code "${input.code}" already exists.`)
      }
      const row: ActivityType = { id: Math.max(...activityTypes.map((a) => a.id)) + 1, iconName: input.iconName ?? null, ...input }
      activityTypes.push(row)
      return row
    }
  }
  const atMatch = /^\/v1\/admin\/activity-types\/(\d+)$/.exec(path)
  if (atMatch && method === 'PATCH') {
    const row = activityTypes.find((a) => a.id === Number(atMatch[1]))
    if (!row) fail(404, 'NOT_FOUND', 'Activity type not found.')
    requireActivityType({ ...row, ...body })
    Object.assign(row, body)
    return row
  }

  if (path === '/v1/admin/exercises') {
    if (method === 'GET') {
      return { items: [...exercises].sort((a, b) => a.sortOrder - b.sortOrder), nextCursor: null }
    }
    if (method === 'POST') {
      const issues: { path: (string | number)[]; message: string }[] = []
      if (!body?.code?.trim()) issues.push({ path: ['code'], message: 'Code is required.' })
      if (!body?.muscleGroup?.trim()) issues.push({ path: ['muscleGroup'], message: 'Muscle group is required.' })
      if (issues.length) validation(issues)
      if (exercises.some((e) => e.code === body.code)) {
        fail(409, 'CONFLICT', `Exercise code "${body.code}" already exists.`)
      }
      const row: WorkoutExercise = {
        id: Math.max(...exercises.map((e) => e.id)) + 1,
        code: body.code,
        muscleGroup: body.muscleGroup,
        equipment: body.equipment || null,
        isUnilateral: !!body.isUnilateral,
        sortOrder: body.sortOrder ?? 0,
      }
      exercises.push(row)
      return row
    }
  }
  const exMatch = /^\/v1\/admin\/exercises\/(\d+)$/.exec(path)
  if (exMatch && method === 'PATCH') {
    const row = exercises.find((e) => e.id === Number(exMatch[1]))
    if (!row) fail(404, 'NOT_FOUND', 'Exercise not found.')
    if (body?.code !== undefined && !String(body.code).trim()) {
      validation([{ path: ['code'], message: 'Code is required.' }])
    }
    Object.assign(row, body)
    return row
  }

  /* translations */
  if (path === '/v1/admin/translations') {
    const entityType = query.get('entityType') ?? ''
    const entityId = query.get('entityId') ?? ''
    if (method === 'GET') {
      if (!entityType || !entityId) {
        validation([{ path: ['entityId'], message: 'entityType and entityId are required.' }])
      }
      return { items: translations.filter((t) => t.entityType === entityType && t.entityId === entityId) }
    }
    if (method === 'PUT') {
      const rows: { locale: string; field: string; value: string }[] = body?.translations ?? []
      const issues: { path: (string | number)[]; message: string }[] = []
      rows.forEach((r, i) => {
        if (!r.value?.trim()) issues.push({ path: ['translations', i, 'value'], message: 'Value cannot be empty.' })
      })
      if (issues.length) validation(issues)
      for (const r of rows) {
        const existing = translations.find(
          (t) => t.entityType === entityType && t.entityId === entityId && t.locale === r.locale && t.field === r.field,
        )
        if (existing) existing.value = r.value
        else {
          translationSeq += 1
          translations.push({ id: translationSeq, entityType, entityId, locale: r.locale, field: r.field, value: r.value })
        }
      }
      return { items: translations.filter((t) => t.entityType === entityType && t.entityId === entityId) }
    }
  }

  /* users */
  if (method === 'GET' && path === '/v1/admin/users') {
    const q = normalise(query.get('q') ?? '')
    const rows = q
      ? users.filter((u) => normalise(`${u.email} ${u.displayName ?? ''}`).includes(q))
      : users
    return paginate(rows, query)
  }
  const roleMatch = /^\/v1\/admin\/users\/([^/]+)\/role$/.exec(path)
  if (roleMatch && method === 'PATCH') {
    const target = users.find((u) => u.id === decodeURIComponent(roleMatch[1]!))
    if (!target) fail(404, 'NOT_FOUND', 'User not found.')
    if (target.id === MOCK_ADMIN_ID && body?.role !== 'admin') {
      fail(403, 'FORBIDDEN', 'You cannot remove your own admin role.')
    }
    if (body?.role !== 'admin' && body?.role !== 'user') {
      validation([{ path: ['role'], message: 'Role must be "admin" or "user".' }])
    }
    target.role = body.role
    return target
  }

  fail(404, 'NOT_FOUND', `No mock route for ${method} ${path}`)
}

function requireActivityType(body: any): ActivityTypeInput {
  const issues: { path: (string | number)[]; message: string }[] = []
  if (!body?.code || !/^[a-z0-9_]+$/.test(body.code)) {
    issues.push({ path: ['code'], message: 'Code must be lower_snake_case.' })
  }
  if (typeof body?.defaultMet !== 'number' || !(body.defaultMet > 0)) {
    issues.push({ path: ['defaultMet'], message: 'MET must be greater than 0.' })
  }
  if (issues.length) validation(issues)
  return body as ActivityTypeInput
}

/* ---- bulk import ------------------------------------------------- */

function parseCsv(text: string): Record<string, string>[] {
  const lines = text.split(/\r?\n/).filter((l) => l.trim())
  if (!lines.length) return []
  const split = (line: string) => {
    const out: string[] = []
    let cur = ''
    let quoted = false
    for (let i = 0; i < line.length; i++) {
      const ch = line[i]!
      if (quoted) {
        if (ch === '"' && line[i + 1] === '"') { cur += '"'; i++ }
        else if (ch === '"') quoted = false
        else cur += ch
      } else if (ch === '"') quoted = true
      else if (ch === ',') { out.push(cur); cur = '' }
      else cur += ch
    }
    out.push(cur)
    return out.map((s) => s.trim())
  }
  const header = split(lines[0]!)
  return lines.slice(1).map((line) => {
    const cells = split(line)
    const row: Record<string, string> = {}
    header.forEach((h, i) => { row[h] = cells[i] ?? '' })
    return row
  })
}

function runImport(body: any) {
  const format: 'csv' | 'json' = body?.format === 'json' ? 'json' : 'csv'
  const content = String(body?.content ?? '')
  let rows: Record<string, unknown>[] = []
  if (format === 'json') {
    try {
      const parsed = JSON.parse(content)
      rows = Array.isArray(parsed) ? parsed : [parsed]
    } catch (e) {
      fail(400, 'VALIDATION_ERROR', `The JSON payload could not be parsed: ${(e as Error).message}`, {
        issues: [{ path: ['content'], message: 'Invalid JSON.' }],
      })
    }
  } else {
    rows = parseCsv(content)
  }
  if (!rows.length) {
    fail(400, 'VALIDATION_ERROR', 'The import file contains no rows.', {
      issues: [{ path: ['content'], message: 'No rows found.' }],
    })
  }

  const results: ImportRowResult[] = []
  let created = 0
  let updated = 0
  let skipped = 0
  let failed = 0

  rows.forEach((raw, i) => {
    const num = (key: string): number | null => {
      const v = raw[key]
      if (v === undefined || v === null || v === '') return null
      const n = Number(v)
      return Number.isFinite(n) ? n : null
    }
    const name = String(raw.name ?? '').trim()
    const kcal = num('caloriesKcal') ?? num('calories_kcal')
    if (!name) {
      failed += 1
      results.push({ row: i + 1, status: 'failed', message: 'name is required' })
      return
    }
    if (kcal === null) {
      failed += 1
      results.push({ row: i + 1, status: 'failed', name, message: 'caloriesKcal is required and must be numeric' })
      return
    }
    const barcode = String(raw.barcode ?? '').trim() || null
    const existing = barcode
      ? foods.find((f) => f.barcode === barcode)
      : foods.find((f) => f.name.toLowerCase() === name.toLowerCase())
    if (existing) {
      if (String(raw.mode ?? '') === 'skip') {
        skipped += 1
        results.push({ row: i + 1, status: 'skipped', foodId: existing.id, name, message: 'already exists' })
        return
      }
      existing.caloriesKcal = kcal
      existing.updatedAt = Date.now()
      existing.embeddingStatus = 'pending'
      updated += 1
      results.push({ row: i + 1, status: 'updated', foodId: existing.id, name })
      return
    }
    const food = insertFood({
      name,
      barcode,
      brand: (raw.brand as string) || null,
      category: (raw.category as string) || null,
      servingSizeG: num('servingSizeG') ?? num('serving_size_g') ?? 100,
      servingLabel: (raw.servingLabel as string) || null,
      caloriesKcal: kcal,
      proteinG: num('proteinG'),
      carbsG: num('carbsG'),
      fatG: num('fatG'),
      saturatedFatG: num('saturatedFatG'),
      fiberG: num('fiberG'),
      sugarG: num('sugarG'),
      sodiumMg: num('sodiumMg'),
      cholesterolMg: num('cholesterolMg'),
      potassiumMg: num('potassiumMg'),
      calciumMg: num('calciumMg'),
      ironMg: num('ironMg'),
    })
    created += 1
    results.push({ row: i + 1, status: 'created', foodId: food.id, name })
  })

  return { total: rows.length, created, updated, skipped, failed, results }
}

/* ---- retrieval preview ------------------------------------------- */

function searchPreview(q: string) {
  if (!q.trim()) {
    validation([{ path: ['q'], message: 'A query is required.' }])
  }
  const nq = normalise(q)
  const terms = nq.split(/\s+/).filter(Boolean)

  const scoreText = (text: string) => {
    const nt = normalise(text)
    let s = 0
    for (const t of terms) {
      if (nt.includes(t)) s += 2 + t.length / 8
      else if (nt.split(/\s+/).some((w) => w.startsWith(t.slice(0, 3)))) s += 0.6
    }
    return s
  }

  type Row = { id: string; corpus: 'foods' | 'food_kb_documents'; title: string; snippet: string | null; s: number }
  const pool: Row[] = [
    ...foods.map((f) => ({
      id: f.id,
      corpus: 'foods' as const,
      title: f.name,
      snippet: `${f.brand ? f.brand + ' · ' : ''}${f.caloriesKcal} kcal / ${f.servingSizeG} g`,
      s: scoreText(`${f.name} ${f.brand ?? ''} ${f.category ?? ''}`),
    })),
    ...kbDocuments.map((d) => ({
      id: d.id,
      corpus: 'food_kb_documents' as const,
      title: d.title,
      snippet: d.content.slice(0, 120) + '…',
      s: scoreText(`${d.title} ${d.content}`),
    })),
  ]

  // BM25 leans lexical: only rows that literally contain a term
  const bm25 = pool
    .filter((r) => r.s > 0)
    .sort((a, b) => b.s - a.s || (a.id < b.id ? -1 : 1))
    .slice(0, 10)
    .map((r, i) => ({
      id: r.id,
      corpus: r.corpus,
      title: r.title,
      snippet: r.snippet,
      rank: i + 1,
      score: Number((r.s * 1.7 + 2).toFixed(3)),
    }))

  // vector leans semantic: nudge in some near-misses that BM25 missed
  const vectorPool = pool
    .map((r) => ({ ...r, s: r.s * 0.8 + (normalise(r.title).length % 7) * 0.11 + (r.corpus === 'food_kb_documents' ? 0.5 : 0) }))
    .sort((a, b) => b.s - a.s || (a.id < b.id ? -1 : 1))
    .slice(0, 10)
  const vector = vectorPool.map((r, i) => ({
    id: r.id,
    corpus: r.corpus,
    title: r.title,
    snippet: r.snippet,
    rank: i + 1,
    score: Number(Math.min(0.98, 0.42 + r.s / 12).toFixed(4)),
  }))

  const rrfK = 60
  const fusedMap = new Map<string, { row: Row; bm25Rank: number | null; vectorRank: number | null; score: number }>()
  const add = (list: { id: string; rank: number }[], key: 'bm25Rank' | 'vectorRank') => {
    for (const item of list) {
      const row = pool.find((p) => p.id === item.id)!
      const entry = fusedMap.get(item.id) ?? { row, bm25Rank: null, vectorRank: null, score: 0 }
      entry[key] = item.rank
      entry.score += 1 / (rrfK + item.rank)
      fusedMap.set(item.id, entry)
    }
  }
  add(bm25, 'bm25Rank')
  add(vector, 'vectorRank')

  const fused = [...fusedMap.values()]
    .sort((a, b) => b.score - a.score)
    .slice(0, 10)
    .map((e, i) => ({
      id: e.row.id,
      corpus: e.row.corpus,
      title: e.row.title,
      snippet: e.row.snippet,
      rank: i + 1,
      fusedScore: Number(e.score.toFixed(5)),
      bm25Rank: e.bm25Rank,
      vectorRank: e.vectorRank,
    }))

  return { q, rrfK, bm25, vector, fused, tookMs: 18 + Math.round(rand(R) * 40) }
}

/* --------------------------------------------------------- install */

let mockRole: 'admin' | 'user' = 'admin'
function getMockRole(): 'admin' | 'user' {
  return mockRole
}
/** Flipped by the login screen's "sign in as non-admin" escape hatch. */
export function setMockRole(role: 'admin' | 'user'): void {
  mockRole = role
}

export function installMockApi(): void {
  const realFetch = window.fetch.bind(window)

  window.fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = new URL(
      typeof input === 'string' ? input : input instanceof URL ? input.toString() : input.url,
      window.location.origin,
    )
    if (!url.pathname.startsWith('/v1/')) return realFetch(input as RequestInfo, init)

    const method = (init?.method ?? 'GET').toUpperCase()
    let body: unknown = undefined
    if (typeof init?.body === 'string') {
      try {
        body = JSON.parse(init.body)
      } catch {
        body = init.body
      }
    }

    await new Promise((r) => setTimeout(r, LATENCY_MS))

    const authed = !!(init?.headers as Record<string, string> | undefined)?.Authorization
    try {
      const result = handle({ method, path: url.pathname, query: url.searchParams, body, authed })
      if (result === null) return new Response(null, { status: 204 })
      return new Response(JSON.stringify(result), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    } catch (err) {
      const e = err as HttpError
      const status = e.status ?? 500
      return new Response(
        JSON.stringify({
          error: { code: e.code ?? 'INTERNAL', message: e.message, details: e.details },
        }),
        { status, headers: { 'Content-Type': 'application/json' } },
      )
    }
  }

  // eslint-disable-next-line no-console
  console.info('[mockApi] installed — every /v1/* request is served from fixtures.')
}
