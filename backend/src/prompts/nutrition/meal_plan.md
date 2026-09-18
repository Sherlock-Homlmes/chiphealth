<!--
Sinh thực đơn một ngày (POST /v1/meal-plans/generate). Gửi làm tin nhắn user sau coach/system.md + coach/context.md.
Biến:
- {{date}}        ngày YYYY-MM-DD
- {{meal_types}}  danh sách bữa, vd "breakfast, lunch, dinner"
-->
Lên thực đơn ngày {{date}} cho các bữa: {{meal_types}}.
Món ăn phải phù hợp khẩu vị Việt Nam, tính đến bệnh nền và mục tiêu.
Trả về DUY NHẤT JSON:
[{"mealType":"breakfast","title":"...","description":"...","targetCaloriesKcal":0,"targetProteinG":0,"targetCarbsG":0,"targetFatG":0,"rationale":"vì sao chọn món này"}]
