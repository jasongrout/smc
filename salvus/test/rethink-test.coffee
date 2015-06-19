async = require('async')
rethink = require '../rethink.coffee'
expect = require('expect')


db = undefined
setup = (cb) ->
    db = rethink.rethinkdb(database:'test', debug:false)
    async.series([
        (cb) ->
            teardown(cb)
        (cb) ->
            db.update_schema(cb:cb)
    ], cb)

teardown = (cb) ->
    db?.delete_all(cb:cb, confirm:'yes')

describe 'working with accounts', ->
    @timeout(5000)
    before(setup)
    after(teardown)
    it 'test creating accounts', (done) ->
        async.series([
            (cb) ->
                db.account_exists
                    email_address:'sage@example.com'
                    cb:(err, exists) -> cb(err or exists)
            (cb) ->
                db.create_account(first_name:"Sage", last_name:"Salvus", created_by:"1.2.3.4",\
                                  email_address:"sage@example.com", password_hash:"blah", cb:cb)
            (cb) ->
                db.account_exists
                    email_address:'sage@example.com'
                    cb:(err, exists) -> cb(err or not exists)
            (cb) ->
                db.create_account(first_name:"Mr", last_name:"Smith", created_by:"10.10.1.1",\
                                  email_address:"sage-2@example.com", password_hash:"foo", cb:cb)
            (cb) ->
                db.get_stats
                    cb: (err, stats) ->
                        cb(err or stats.accounts != 2)
            (cb) ->
                db.get_account
                    email_address:'sage-2@example.com'
                    cb:(err, account) ->
                        if err
                            cb(err)
                        else
                            cb(account.first_name=="Mr" and account.password_is_set)
            (cb) ->
                db.count_accounts_created_by
                    ip_address : '1.2.3.4'
                    age_s      : 1000000
                    cb         : (err, n) ->
                        cb(err or n != 1)
        ], (err) ->
            expect(err).toBe(undefined)
            done()
        )

    it 'test deleting accounts', (done) ->
        account_id = undefined
        n_start = undefined
        async.series([
            (cb) ->
                db.table('accounts').count().run (err, n) ->
                    n_start = n; cb(err)
            (cb) ->
                db.get_account
                    email_address:'sage-2@example.com'
                    cb : (err, account) ->
                        expect(account?).toBe(true)
                        account_id = account.account_id
                        cb(err)
            (cb) ->
                db.delete_account
                    account_id : account_id
                    cb         : cb
            (cb) ->
                db.table('accounts').count().run (err, n) ->
                    expect(n).toBe(n_start - 1)
                    cb(err)
        ], (err) ->
            expect(err).toBe(undefined)
            done()
        )

describe 'working with logs', ->
    before(setup)
    after(teardown)
    it 'test central log', (done) ->
        async.series([
            (cb) ->
                db.log
                    event : "test"
                    value : "a message"
                    cb    : cb
            (cb) ->
                db.get_log
                    start : new Date(new Date() - 10000000)
                    end   : new Date()
                    event : 'test'
                    cb    : (err, log) ->
                        cb(err or log.length != 1 or log[0].event != 'test' or log[0].value != 'a message')
        ], (err) ->
            expect(err).toBe(undefined)
            done()
        )

describe 'testing working with blobs -- ', ->
    beforeEach(setup)
    afterEach(teardown)
    {uuidsha1} = require('../misc_node')
    it 'creating a blob and reading it', (done) ->
        blob = new Buffer("This is a test blob")
        async.series([
            (cb) ->
                db.save_blob(uuid : uuidsha1(blob), blob : blob, cb   : cb)
            (cb) ->
                db.table('blobs').count().run (err, n) ->
                    expect(n).toBe(1)
                    cb(err)
            (cb) ->
                db.get_blob
                    uuid : uuidsha1(blob)
                    cb   : (err, blob2) ->
                        expect(blob2.equals(blob)).toBe(true)
                        cb(err)
        ], done)

    it 'creating 50 blobs and verifying that 50 are in the table', (done) ->
        async.series([
            (cb) ->
                f = (n, cb) ->
                    blob = new Buffer("x#{n}")
                    db.save_blob(uuid : uuidsha1(blob), blob : blob, cb   : cb)
                async.map([0...50], f, cb)
            (cb) ->
                db.table('blobs').count().run (err, n) ->
                    expect(n).toBe(50)
                    cb(err)
        ], done)

    it 'creating 5 blobs that expire in 0.01 second and 5 that do not, then wait 0.1s, delete_expired, then verify that the expired ones are gone from the table', (done) ->
        async.series([
            (cb) ->
                f = (n, cb) ->
                    blob = new Buffer("x#{n}")
                    db.save_blob(uuid : uuidsha1(blob), blob : blob, cb   : cb, ttl:if n<5 then 0.01 else 0)
                async.map([0...10], f, cb)
            (cb) ->
                setTimeout(cb, 100)
            (cb) ->
                db.delete_expired(cb:cb)
            (cb) ->
                db.table('blobs').count().run (err, n) ->
                    expect(n).toBe(5)
                    cb(err)
        ], done)

    it 'creating a blob that expires in 0.01 seconds, then extending it to never expire; wait, delete, and ensure it is still there', (done) ->
        blob = "a blob"
        uuid = uuidsha1(blob)
        async.series([
            (cb) ->
                db.save_blob(uuid : uuid, blob : blob, cb : cb, ttl:0.01)
            (cb) ->
                db.remove_blob_ttls(uuids:[uuid], cb:cb)
            (cb) ->
                setTimeout(cb, 100)
            (cb) ->
                db.table('blobs').count().run (err, n) ->
                    expect(n).toBe(1)
                    cb(err)
        ], done)




describe 'testing the hub servers registration table', ->
    beforeEach(setup)
    afterEach(teardown)
    it 'test registering a hub that expires in 0.05 seconds, test is right, then wait 0.1s, delete_expired, then verify done', (done) ->
        async.series([
            (cb) ->
                db.register_hub(host:"smc0", port:5000, clients:17, ttl:0.05, cb:cb)
            (cb) ->
                db.get_hub_servers cb:(err, v) ->
                    expect(v.length).toBe(1)
                    expect(v[0]).toEqual({host:"smc0", port:5000, clients:17, expire:v[0].expire})
                    cb(err)
            (cb) ->
                setTimeout(cb, 150)
            (cb) ->
                db.delete_expired(cb:cb)
            (cb) ->
                db.get_hub_servers cb:(err, v) ->
                    expect(v.length).toBe(0)
                    cb(err)
        ], done)