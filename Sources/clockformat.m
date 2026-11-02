//
//  clockformat.m
//  Time2 格式化实现：24 小时 HH:mm（本版不渲染日期，原生日期保留）
//

#import "clockformat.h"

NSString *t2ClockString(void) {
    NSDateComponents *c = [[NSCalendar currentCalendar]
                           components:(NSCalendarUnitHour | NSCalendarUnitMinute)
                           fromDate:[NSDate date]];
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)c.hour, (long)c.minute];
}
