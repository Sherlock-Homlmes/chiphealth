<!--
Tin nhắn sửa (role=user) nhét vào loop khi model trả lời kiểu "mình sẽ kiểm tra dữ liệu..."
mà lượt đó CHƯA gọi tool đọc nào — model hứa tra cứu rồi kết thúc lượt, người dùng chỉ nhận lời hứa.
services/agent/agent.ts dùng sau khi kiểm tra promisesLookup(). Không có biến.
-->
Bạn vừa nói sẽ đi xem/kiểm tra dữ liệu, nhưng bạn chưa gọi tool đọc nào trong lượt này nên KHÔNG có dữ liệu nào được tra — người dùng chỉ nhận được một lời hứa và không thể bấm gì để bạn tra giúp cả.

Tool ĐỌC (get_*, list_*, search_*) chạy NGAY LẬP TỨC và không cần người dùng cho phép: đây là dữ liệu của chính họ. Hãy gọi các tool cần thiết NGAY BÂY GIỜ trong lượt này (được gọi nhiều tool cùng lúc, nhiều vòng), đợi kết quả rồi mới viết câu trả lời dựa trên số liệu thật.

Nếu không cần tra gì: trả lời thẳng câu hỏi và KHÔNG viết những câu kiểu "mình sẽ kiểm tra", "để mình xem lại".
