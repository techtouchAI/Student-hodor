/// حراسة الأخطاء: لا صفحة بيضاء صامتة بعد الآن.
///
/// في وضع Release يرسم Flutter ودجت الخطأ **فارغاً** (مربع أبيض) عندما يرمي أي
/// ودجت استثناءً أثناء البناء، وكانت النتيجة «شاشة بيضاء» بلا أي دليل. هذه
/// الطبقة تفعل ثلاثة أمور:
///
/// 1. [installErrorGuards] يستبدل ودجت الخطأ الفارغ ببطاقة حمراء مقروءة تحمل
///    نص العطل نفسه، ويسجّل كل عطل (بناء/غير متزامن) في [AppErrorLog].
/// 2. [ErrorBoundary] يغلّف كل مسار: إن فشل بناء الشاشة كاملة تُعرض [CrashScreen]
///    بدل البياض، مع نسخ التقرير.
/// 3. [StreamGuard]/[LoadErrorCard] يحوّلان أخطاء تدفقات قاعدة البيانات من
///    «شاشة فارغة» إلى رسالة + زر إعادة محاولة.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/error_log.dart';

/// يثبّت الحراسات العامة مرة واحدة عند الإقلاع.
void installErrorGuards() {
  FlutterError.onError = (FlutterErrorDetails details) {
    AppErrorLog.instance.record(
      details.exception,
      details.stack ?? StackTrace.current,
      where: _contextLabel(details),
    );
    // في وضع الإصدار: ودجت الخطأ الافتراضي فارغ ⇒ بياض. نعرضه مقروءاً.
    FlutterError.presentError(details);
    _notifyBoundary(details);
  };
  ErrorWidget.builder = (FlutterErrorDetails details) {
    AppErrorLog.instance.record(
      details.exception,
      details.stack ?? StackTrace.current,
      where: _contextLabel(details),
    );
    _notifyBoundary(details);
    return VisibleErrorWidget(details: details);
  };
  // أخطاء المنصة/غير المتزامنة التي لا تمرّ على FlutterError (مثل ردود قنوات
  // المنصة). محاطة بمحاولة/التقاط: إن لم يكن الربط مهيّأً (كما في بعض
  // الاختبارات) تكفي الحراستان أعلاه ولا يجوز أن ينهار الإقلاع بسببها.
  try {
    PlatformDispatcher.instance.onError =
        (Object error, StackTrace stack) {
      AppErrorLog.instance.record(error, stack, where: 'async');
      return true;
    };
  } catch (_) {
    // لا شيء: الحراسة اختيارية هنا.
  }
}

String _contextLabel(FlutterErrorDetails details) {
  final DiagnosticsNode? ctx = details.context;
  if (ctx == null) {
    return details.library ?? 'flutter';
  }
  final String s = ctx.toString();
  return s.length > 120 ? s.substring(0, 120) : s;
}

/// يبلّغ أقرب [ErrorBoundary] أعلى الشجرة إن وُجد (لتبديل الشاشة كاملة).
void _notifyBoundary(FlutterErrorDetails details) {
  final Element? element = _elementOf(details.context);
  if (element == null) {
    return;
  }
  try {
    element.visitAncestorElements((Element ancestor) {
      final StatefulElement? se =
          ancestor is StatefulElement ? ancestor : null;
      if (se != null && se.state is ErrorBoundaryState) {
        (se.state as ErrorBoundaryState).report(
          details.exception,
          details.stack ?? StackTrace.current,
        );
        return false;
      }
      return true;
    });
  } catch (_) {
    // الشجرة قد تكون مفككة أثناء العطل — لا نضيف عطلاً ثانياً.
  }
}

Element? _elementOf(DiagnosticsNode? node) {
  if (node == null) {
    return null;
  }
  final Object? v = node.value;
  return v is Element ? v : null;
}

/// ودجت الخطأ المرئي: يستبدل المربع الأبيض الفارغ في وضع Release.
class VisibleErrorWidget extends StatelessWidget {
  const VisibleErrorWidget({super.key, required this.details});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String message = '${details.exception}';
    return Material(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.report_problem, color: cs.onErrorContainer, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'جزء من الشاشة تعذّر رسمه',
                    style: TextStyle(
                      color: cs.onErrorContainer,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              message.length > 400 ? message.substring(0, 400) : message,
              style: TextStyle(
                color: cs.onErrorContainer,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// بطاقة خطأ مقروءة بدل أي جسم فارغ.
class LoadErrorCard extends StatelessWidget {
  const LoadErrorCard({
    super.key,
    required this.message,
    this.onRetry,
    this.compact = false,
  });

  final String message;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.all(compact ? 8 : 16),
      child: Card(
        color: cs.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.report_problem, color: cs.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      compact ? 'تعذر التحميل' : 'تعذر تحميل هذه الشاشة',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: cs.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(message, style: TextStyle(color: cs.onErrorContainer)),
              if (onRetry != null) ...<Widget>[
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('إعادة المحاولة'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// StreamBuilder موحّد: مؤشر تحميل، رسالة خطأ واضحة، ثم البيانات.
///
/// النمط السابق (`snap.data ?? []`) كان يبتلع أخطاء قاعدة البيانات فيظهر
/// «لا بيانات» كاذبة؛ الآن الخطأ يُعرض برسالة مع زر إعادة المحاولة.
class StreamGuard<T> extends StatefulWidget {
  const StreamGuard({
    super.key,
    required this.stream,
    required this.builder,
    this.loading,
  });

  final Stream<T> stream;
  final Widget Function(BuildContext context, T data) builder;
  final Widget? loading;

  @override
  State<StreamGuard<T>> createState() => _StreamGuardState<T>();
}

class _StreamGuardState<T> extends State<StreamGuard<T>> {
  // مفتاح يُزاد عند «إعادة المحاولة» لإعادة إنشاء الاشتراك من الصفر.
  int _attempt = 0;

  @override
  Widget build(BuildContext context) => StreamBuilder<T>(
        key: ValueKey<int>(_attempt),
        stream: widget.stream,
        builder: (BuildContext context, AsyncSnapshot<T> snap) {
          if (snap.hasError) {
            AppErrorLog.instance.record(
              snap.error!,
              snap.stackTrace ?? StackTrace.current,
              where: 'stream:${T.toString()}',
            );
            return Center(
              child: LoadErrorCard(
                message: '${snap.error}',
                onRetry: () => setState(() => _attempt++),
              ),
            );
          }
          // لم يصل أول حدث بعد ⇒ تحميل. وما عدا ذلك نبني بالقيمة المتاحة
          // (قد تكون null شرعية كما في `Stream<Session?>`).
          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return widget.loading ??
                const Center(child: CircularProgressIndicator());
          }
          return widget.builder(context, snap.data as T);
        },
      );
}

/// يغلّف شاشة كاملة: إن فشل بناؤها تُعرض [CrashScreen] بدل صفحة بيضاء.
class ErrorBoundary extends StatefulWidget {
  const ErrorBoundary({super.key, required this.child, this.routeLabel = ''});

  final Widget child;

  /// اسم الشاشة — يظهر في سجل الأعطال ليسهل التشخيص عن بُعد.
  final String routeLabel;

  @override
  State<ErrorBoundary> createState() => ErrorBoundaryState();
}

class ErrorBoundaryState extends State<ErrorBoundary> {
  Object? _error;
  StackTrace? _stack;

  /// يُستدعى من [ErrorWidget.builder] العام عند فشل أي ودجت داخل هذه الشاشة.
  void report(Object error, StackTrace stack) {
    if (!mounted || _error != null) {
      return;
    }
    setState(() {
      _error = error;
      _stack = stack;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Object? e = _error;
    if (e == null) {
      return widget.child;
    }
    return CrashScreen(
      error: e,
      stackTrace: _stack,
      contextLabel: widget.routeLabel,
    );
  }
}

/// شاشة عطل مقروءة: السبب + أول أسطر التتبع + نسخ + عودة.
class CrashScreen extends StatelessWidget {
  const CrashScreen({
    super.key,
    required this.error,
    this.stackTrace,
    this.contextLabel = '',
    this.title = 'تعذر فتح هذه الشاشة',
  });

  final Object error;
  final StackTrace? stackTrace;
  final String contextLabel;
  final String title;

  String get report {
    final String st = stackTrace?.toString() ?? '';
    final List<String> lines = st
        .split('\n')
        .where((String l) => l.trim().isNotEmpty)
        .take(14)
        .toList();
    return 'السياق: ${contextLabel.isEmpty ? 'غير محدد' : contextLabel}\n'
        'الخطأ: $error\n'
        'أهم الأسطر:\n${lines.join('\n')}';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('عطل في الشاشة'),
        backgroundColor: cs.errorContainer,
        foregroundColor: cs.onErrorContainer,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Icon(Icons.error_outline, size: 56, color: cs.error),
          const SizedBox(height: 8),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          const Text(
            'لم تعد الصفحة بيضاء صامتة: هذا سبب العطل حرفياً. '
            'انسخه أو أرسله ليُصلح من جذره.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(
              report,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: <Widget>[
              FilledButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: report));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('نُسخ تقرير العطل')),
                    );
                  }
                },
                icon: const Icon(Icons.copy),
                label: const Text('نسخ التقرير'),
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back),
                label: const Text('رجوع'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
