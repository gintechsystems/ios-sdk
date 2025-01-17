#import "CleverSDK.h"

@interface CleverSDK () 

@property (nonatomic, strong) NSString *clientId;
@property (nonatomic, strong) NSString *legacyIosClientId;
@property (nonatomic, strong) NSString *redirectUri;

@property (nonatomic, strong) UIViewController *viewController;

@property (nonatomic, strong) NSString *state;
@property (atomic, assign) BOOL alreadyMissedCode;

@property (nonatomic, copy) void (^successHandler)(NSString *, BOOL);
@property (nonatomic, copy) void (^failureHandler)(NSString *);

+ (instancetype)sharedManager;

@end

@implementation CleverSDK

+ (instancetype)sharedManager {
    static CleverSDK *_sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedManager = [[self alloc] init];
    });
    return _sharedManager;
}

+ (void) startWithClientId:(NSString *)clientId LegacyIosClientId:(NSString *)legacyIosClientId RedirectURI:(NSString *)redirectUri successHandler:(void (^)(NSString *code, BOOL validState))successHandler failureHandler:(void (^)(NSString *errorMessage))failureHandler {
    CleverSDK *manager = [self sharedManager];
    manager.clientId = clientId;
    manager.alreadyMissedCode = NO;
    manager.legacyIosClientId = legacyIosClientId;
    manager.redirectUri = redirectUri;
    manager.successHandler = successHandler;
    manager.failureHandler = failureHandler;
}

+ (void) startWithClientId:(NSString *)clientId LegacyIosClientId:(NSString *)legacyIosClientId RedirectURI:(NSString *)redirectUri ViewController:(UIViewController *)viewController successHandler:(void (^)(NSString *code, BOOL validState))successHandler failureHandler:(void (^)(NSString *errorMessage))failureHandler {
    CleverSDK *manager = [self sharedManager];
    manager.clientId = clientId;
    manager.alreadyMissedCode = NO;
    manager.legacyIosClientId = legacyIosClientId;
    manager.redirectUri = redirectUri;
    manager.viewController = viewController;
    manager.successHandler = successHandler;
    manager.failureHandler = failureHandler;
}

+ (void)startWithClientId:(NSString *)clientId RedirectURI:(NSString *)redirectUri successHandler:(void (^)(NSString *code, BOOL validState))successHandler failureHandler:(void (^)(NSString *errorMessage))failureHandler {
    [self startWithClientId:clientId LegacyIosClientId:nil RedirectURI:redirectUri ViewController:nil successHandler:successHandler failureHandler:failureHandler];
}

+ (void)startWithClientId:(NSString *)clientId RedirectURI:(NSString *)redirectUri ViewController:(UIViewController *)viewController successHandler:(void (^)(NSString *code, BOOL validState))successHandler failureHandler:(void (^)(NSString *errorMessage))failureHandler {
    [self startWithClientId:clientId LegacyIosClientId:nil RedirectURI:redirectUri ViewController:viewController successHandler:successHandler failureHandler:failureHandler];
}

+ (NSString *)generateRandomString:(int)length {
    NSAssert(length % 2 == 0, @"Must generate random string with even length");
    NSMutableData *data = [NSMutableData dataWithLength:length / 2];
    NSAssert(SecRandomCopyBytes(kSecRandomDefault, length, [data mutableBytes]) == 0, @"Failure in SecRandomCopyBytes: %d", errno);
    NSMutableString *hexString  = [NSMutableString stringWithCapacity:(length)];
    const unsigned char *dataBytes = [data bytes];
    for (int i = 0; i < length / 2; ++i)
    {
        [hexString appendFormat:@"%02x", (unsigned int)dataBytes[i]];
    }
    return [NSString stringWithString:hexString];
}

+ (void)login {
    [self loginWithDistrictId:nil];
}

+ (void)loginWithDistrictId:(NSString *)districtId {
    CleverSDK *manager = [self sharedManager];
    manager.state = [self generateRandomString:32];
    
    NSString *legacyIosRedirectURI = nil;
    if (manager.legacyIosClientId != nil) {
        legacyIosRedirectURI = [NSString stringWithFormat:@"clever-%@://oauth", manager.legacyIosClientId];
    }
    
    NSString *webURLString = [NSString stringWithFormat:@"https://clever.com/oauth/authorize?response_type=code&client_id=%@&redirect_uri=%@&state=%@", manager.clientId, manager.redirectUri, manager.state];
    NSString *cleverAppURLString = [NSString stringWithFormat:@"com.clever://oauth/authorize?response_type=code&client_id=%@&redirect_uri=%@&state=%@&sdk_version=%@", manager.legacyIosClientId, legacyIosRedirectURI, manager.state, SDK_VERSION];
    
    if (districtId != nil) {
        webURLString = [NSString stringWithFormat:@"%@&district_id=%@", webURLString, districtId];
        cleverAppURLString = [NSString stringWithFormat:@"%@&district_id=%@", cleverAppURLString, districtId];
    }
    
    // Switch to native Clever app if possible
    if ([[UIApplication sharedApplication] canOpenURL:[NSURL URLWithString:cleverAppURLString]] && manager.legacyIosClientId != nil) {
        if (@available(iOS 10, *)) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:cleverAppURLString] options:@{} completionHandler:nil];
        } else {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:cleverAppURLString]];
        }
        return;
    }
    
    // If a view controller parameter value was passed to this method, we want to present the safari view controller instead of opening the safari app.
    if (manager.viewController) {
        SmartWKWebViewController *smart = [[SmartWKWebViewController alloc] init];
        smart.url = [NSURL URLWithString:webURLString];
        [smart setDelegate:manager];
        [manager.viewController presentViewController:smart animated:YES completion:nil];
        return;
    }
    
    // Looks like the Clever app is not installed and a view controller value was not passed, we should do something...open the safari app.
    if (@available(iOS 10, *)) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:webURLString] options:@{} completionHandler:nil];
    } else {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:webURLString]];
    }
}

+ (BOOL)handleURL:(NSURL *)url {
    CleverSDK *manager = [self sharedManager];

    NSURL *redirectURL = [NSURL URLWithString:manager.redirectUri];
    
    if (!(
        [url.scheme isEqualToString:[NSString stringWithFormat:@"clever-%@", manager.legacyIosClientId]] || (
            [url.scheme isEqualToString:redirectURL.scheme] &&
            [url.host isEqualToString:redirectURL.host] &&
            [url.path isEqualToString:redirectURL.path]
    ))) {
        return NO;
    }
    
    NSString *query = url.query;
    NSMutableDictionary *kvpairs = [NSMutableDictionary dictionaryWithCapacity:1];
    NSArray *components = [query componentsSeparatedByString:@"&"];
    for (NSString *component in components) {
        NSArray *kv = [component componentsSeparatedByString:@"="];
        kvpairs[kv[0]] = kv[1];
    }
    
    // if code is missing, then this is a Clever Portal initiated login, and we should kick off the Oauth flow
    NSString *code = kvpairs[@"code"];
    if (!code) {
        CleverSDK* manager = [self sharedManager];
        if (manager.alreadyMissedCode) {
            manager.alreadyMissedCode = NO;
            manager.failureHandler([NSString localizedStringWithFormat:@"Authorization failed. Please try logging in again."]);
            return YES;
        }
        manager.alreadyMissedCode = YES;
        [self login];
        return YES;
    }
    
    BOOL validState = NO;
    
    NSString *state = kvpairs[@"state"];
    if ([state isEqualToString:manager.state]) {
        validState = YES;
    }
    
    manager.successHandler(code, validState);
    return YES;
}
    
- (void)decidePolicyWithWebView:(WKWebView *)webView navigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    // Check for Clever code in the upcoming request URL, if it is available then let Clever manager handle it.
    if ([navigationAction.request.URL.absoluteString containsString:@"code="]) {
        [CleverSDK handleURL:navigationAction.request.URL];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    
    decisionHandler(WKNavigationActionPolicyAllow);
}

@end
