//
//  clockformat.h
//  Time2 锁屏大字时钟格式化接口（本版不渲染日期，原生日期保留）
//

#ifndef T2_CLOCKFORMAT_H
#define T2_CLOCKFORMAT_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// 24 小时制 "HH:mm"，两位补零，不带秒（参考图 10:03）
NSString *t2ClockString(void);

#ifdef __cplusplus
}
#endif

#endif
