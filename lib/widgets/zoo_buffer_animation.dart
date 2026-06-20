import 'package:flutter/material.dart';

/// ZOO AI кастомная анимация буферизации
/// 🦡 (Крот) -> 🐗 (Кабан) -> 🦫 (Бобер) -> 🐈 (Кот) -> 🐷🏦 (Поросенок с сейфом)
class ZooBufferAnimation extends StatefulWidget {
  final double progress; // 0.0 to 1.0

  const ZooBufferAnimation({super.key, required this.progress});

  @override
  State<ZooBufferAnimation> createState() => _ZooBufferAnimationState();
}

class _ZooBufferAnimationState extends State<ZooBufferAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _paperPosition;

  final List<String> characters = ['🦡', '🐗', '🦫', '🐈', '🐷🏦'];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();

    _paperPosition = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        decoration: BoxDecoration(
          color: const Color(0xEE0D0D12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.orange.withOpacity(0.5), width: 2),
          boxShadow: [
            BoxShadow(
              color: Colors.orange.withOpacity(0.2),
              blurRadius: 20,
              spreadRadius: 2,
            )
          ],
        ),
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Заголовок
            const Text(
              'ZOO AI ЗАГРУЗКА',
              style: TextStyle(
                color: Colors.orange,
                fontSize: 18,
                fontWeight: FontWeight.bold,
                letterSpacing: 2.0,
                shadows: [Shadow(color: Colors.orangeAccent, blurRadius: 8)],
              ),
            ),
            const SizedBox(height: 30),

            // Анимация передачи листка
            SizedBox(
              height: 50,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Персонажи
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: characters
                        .map((c) => Text(c, style: const TextStyle(fontSize: 28)))
                        .toList(),
                  ),
                  // Летающий листок
                  AnimatedBuilder(
                    animation: _paperPosition,
                    builder: (context, child) {
                      return Align(
                        // Перевод позиции 0.0 -> 1.0 в Alignment (-1.0 -> 1.0)
                        alignment: Alignment(-1.0 + (_paperPosition.value * 2.0), 0),
                        child: const Text('📄', style: TextStyle(fontSize: 20)),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),

            // Прогресс-бар
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: widget.progress.clamp(0.0, 1.0),
                minHeight: 12,
                backgroundColor: Colors.white10,
                color: Colors.orange,
              ),
            ),
            const SizedBox(height: 12),
            
            // Текст прогресса
            Text(
              'БУФЕР: ${(widget.progress * 100).toInt().clamp(0, 100)}%',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
