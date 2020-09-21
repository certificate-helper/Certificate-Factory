#import "CRFFactory.h"
#include <openssl/pkcs12.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>

@interface CRFFactory ()

@property (strong, nonatomic, nonnull) CRFFactoryOptions * options;

@end

@implementation CRFFactory

+ (CRFFactory *) factoryWithOptions:(CRFFactoryOptions *)options {
    CRFFactory * factory = CRFFactory.new;

    factory.options = options;

    return factory;
}

- (void) generateAndSave:(void (^)(NSString *, NSError *))finished {
    OPENSSL_init_ssl(0, NULL);
    OPENSSL_init_crypto(0, NULL);

    NSError * rootError;
    NSError * serverError;
    CRFCertificate * root = [self.options.rootRequest generate:&rootError];
    if (rootError != nil) {
        finished(nil, rootError);
        return;
    }
    NSMutableArray<CRFCertificate *> * serverCerts = [NSMutableArray arrayWithCapacity:self.options.serverRequests.count];
    for (CRFCertificateRequest * serverRequest in self.options.serverRequests) {
        serverRequest.rootPkey = root.pkey;
        [serverCerts addObject:[serverRequest generate:&serverError]];
        if (serverError != nil) {
            finished(nil, serverError);
            return;
        }
    }

    switch (self.options.exportOptions.exportType) {
        case EXPORT_PEM:
            [self savePEMWithRootCert:root serverCerts:serverCerts password:self.options.exportOptions.exportPassword finished:finished];
            break;
        case EXPORT_PKCS12:
            [self saveP12WithRoot:root serverCerts:serverCerts password:self.options.exportOptions.exportPassword finished:finished];
            break;
    }
}

- (void) savePEMWithRootCert:(CRFCertificate *)root serverCerts:(NSArray<CRFCertificate *> *)serverCerts password:(NSString *)password finished:(void (^)(NSString *, NSError *))finished {
    NSURL *directoryURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSProcessInfo.processInfo globallyUniqueString]] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:nil];
    NSError * (^exportCert)(CRFCertificate *) = ^NSError *(CRFCertificate * cert) {
        NSString * keyPath = [NSString stringWithFormat:@"%@/%@.key", directoryURL.path, cert.name];
        NSString * certPath = [NSString stringWithFormat:@"%@/%@.crt", directoryURL.path, cert.name];

        FILE * f = fopen(keyPath.fileSystemRepresentation, "wb");
        if (PEM_write_PrivateKey(f,
                                 cert.pkey,
                                 self.options.exportOptions.encryptKey ? EVP_des_ede3_cbc() : NULL,
                                 self.options.exportOptions.encryptKey ? (unsigned char *)[password UTF8String] : NULL,
                                 self.options.exportOptions.encryptKey ? (int)password.length : 0,
                                 NULL,
                                 NULL) < 0) {
            fclose(f);
            return [self opensslError:@"Error saving private key"];
        }
        NSLog(@"Saved key to %@", keyPath);
        fclose(f);

        f = fopen(certPath.fileSystemRepresentation, "wb");
        if (PEM_write_X509(f, cert.x509) < 0) {
            fclose(f);
            return [self opensslError:@"Error saving certificate"];
        }
        NSLog(@"Saved cert to %@", certPath);
        fclose(f);
        return nil;
    };

    NSError * exportError;

    if (!root.imported) {
        if ((exportError = exportCert(root)) != nil) {
            finished(nil, exportError);
            return;
        }
    }
    for (CRFCertificate * cert in serverCerts) {
        if ((exportError = exportCert(cert)) != nil) {
            finished(nil, exportError);
            return;
        }
    }

    finished(directoryURL.path, nil);
}

- (void) saveP12WithRoot:(CRFCertificate *)root serverCerts:(NSArray<CRFCertificate *> *)serverCerts password:(NSString *)password finished:(void (^)(NSString *, NSError *))finished {
    NSURL *directoryURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSProcessInfo.processInfo globallyUniqueString]] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:nil];
    NSError * (^exportCert)(CRFCertificate *, X509 *) = ^NSError *(CRFCertificate * cert, X509 * rootCert) {
        NSString * path = [NSString stringWithFormat:@"%@/%@.p12", directoryURL.path, cert.name];
        struct stack_st_X509 * rootStack = sk_X509_new_null();
        if (rootCert != NULL) {
            sk_X509_push(rootStack, rootCert);
        }
        PKCS12 * p12 = PKCS12_create(
                                     [password UTF8String], // password
                                     NULL, // name
                                     cert.pkey, // pkey
                                     cert.x509, // cert
                                     rootCert != NULL ? rootStack : NULL, // cas
                                     0, // nid key
                                     0, // nid cert
                                     PKCS12_DEFAULT_ITER, // iter
                                     1, // mac iterm
                                     NID_key_usage // keytype
                                     );
        FILE * f = fopen(path.fileSystemRepresentation, "wb");

        if (i2d_PKCS12_fp(f, p12) != 1) {
            fclose(f);
            return [self opensslError:@"Error writing p12 to disk."];
        }
        NSLog(@"Saved p12 to %@", path);
        fclose(f);
        return nil;
    };

    NSError * exportError;

    if (!root.imported) {
        if ((exportError = exportCert(root, NULL)) != nil) {
            finished(nil, exportError);
            return;
        }
    }
    for (CRFCertificate * cert in serverCerts) {
        if ((exportError = exportCert(cert, root.x509)) != nil) {
            finished(nil, exportError);
            return;
        }
    }

    finished(directoryURL.path, nil);
}

- (NSError *) opensslError:(NSString *)description {
    const char * file;
    int line;
    ERR_peek_last_error_line(&file, &line);
    NSString * errorBody = [NSString stringWithFormat:@"%@ - OpenSSL Error %s:%i", description, file, line];
    NSLog(@"%@", errorBody);
    return NSMakeError(errorBody);
}

@end
