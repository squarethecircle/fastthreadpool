# Copyright 2018 Martin Bammer. All Rights Reserved.
# Licensed under MIT license.
#cython: boundscheck=False
#cython: wraparound=False
#cython: initializedcheck=False
#cython: cdivision=True
#cython: optimize.use_switch=True
#cython: optimize.unpack_method_calls=False
#cython: unraisable_tracebacks=True

"""Implements a lightweight and fast thread pool."""

__author__ = 'Martin Bammer (mrbm74@gmail.com)'

cdef sys, isgeneratorfunction, Lock, Thread, Timer, islice, deque, _time, sleep, cpu_count
import sys
import atexit
from inspect import isgeneratorfunction
from threading import Lock, Thread, Timer
from itertools import islice
from time import sleep, mktime, struct_time
try:
    from time import monotonic as _time
except ImportError:
    from time import time as _time
from collections import deque
if sys.version_info[0] > 2:
    from os import cpu_count
else:
    from multiprocessing import cpu_count

if sys.version_info[0] < 3:
    class TimeoutError(Exception):
        pass


class PoolCallback(Exception):
    pass


class PoolStopped(Exception):
    pass


cdef set _pools
_pools = set()

LOGGER_NAME = 'fastthreadpool'
DEFAULT_LOGGING_FORMAT = '[%(levelname)s/%(processName)s] %(message)s'


def shutdown(now=True):
    for pool in _pools:
        if now:
            pool.shutdown_children()
            pool.cancel(None, True)
            pool.shutdown(None, True)
        else:
            pool.cancel(None, False)
            pool.shutdown()


atexit.register(shutdown)

from cpython cimport pythread
from cpython.exc cimport PyErr_NoMemory


cdef class Semaphore:
#p class Semaphore(object):  
    """Fast semaphore.
    """
    cdef pythread.PyThread_type_lock _lock, _value_lock
    cdef int _value

    def __cinit__(self, int value=1):
    #p def __init__(self, value=1):  
        if value < 0:
            raise ValueError( "Semaphore: Parameter 'value' must not be less than 0")
        self._lock = pythread.PyThread_allocate_lock()
        if not self._lock:
            raise MemoryError()
        self._value_lock = pythread.PyThread_allocate_lock()
        if not self._value_lock:
            raise MemoryError()
        #p self._lock = Lock()  
        #p self._value_lock = Lock()  
        self._value = value

    def __dealloc__(self):
        if self._lock:
            pythread.PyThread_free_lock(self._lock)
            self._lock = NULL
        if self._value_lock:
            pythread.PyThread_free_lock(self._value_lock)
            self._value_lock = NULL

    @property
    def value(self):
        return self._value

    cpdef bint acquire(self, bint blocking=True):
    #p def acquire(self, blocking=True):  
        cdef int value, wait
        pythread.PyThread_acquire_lock(self._value_lock, 1)
        #p self._value_lock.acquire()  
        self._value -= 1
        value = self._value
        pythread.PyThread_release_lock(self._value_lock)
        #p self._value_lock.release()  
        if value >= 0:
            return False
        with nogil:
        #p if True:  
            wait = pythread.WAIT_LOCK if blocking else pythread.NOWAIT_LOCK
            #p wait = blocking  
            while True:
                if pythread.PyThread_acquire_lock(self._lock, wait):
                #p if self._lock.acquire(wait):  
                    break
                if wait == pythread.NOWAIT_LOCK:
                #p if not wait:  
                    return False
        return True

    cpdef void release(self):
    #p def release(self):  
        pythread.PyThread_acquire_lock(self._value_lock, 1)
        #p self._value_lock.acquire()  
        self._value += 1
        if self._value >= 0:
            pythread.PyThread_release_lock(self._lock)
            #p self._lock.release()  
        pythread.PyThread_release_lock(self._value_lock)
        #p self._value_lock.release()  


class TimerObj(object):

    def __init__(self):
        self.old_timer_id = None   # Old timer id
        self.timer_id = None


cdef class Pool:
#p class Pool(object):  

    cdef Semaphore _job_cnt
    cdef set children
    cdef int max_children
    cdef str child_name_prefix
    cdef bint result_id
    cdef int _child_cnt, _busy_cnt
    cdef pythread.PyThread_type_lock _busy_lock
    cdef object _delayed, _scheduled, _jobs, _jobs_append, _jobs_appendleft, _done, _failed
    cdef Semaphore _done_cnt, _failed_cnt
    cdef bint _shutdown, _shutdown_children
    cdef object logger
    cdef object init_callback
    cdef object _thr_done, _thr_failed

    def __cinit__(self, int max_children=-9999, str child_name_prefix="", init_callback=None,
                  done_callback=None, failed_callback=None, int log_level=0, bint result_id=False):
    #p def __init__(self, max_children=-9999, child_name_prefix="", init_callback=None,  
                 #p done_callback=None, failed_callback=None, log_level=None, result_id=False):  
        self._job_cnt = Semaphore(0)
        self.children = set()
        if max_children <= -9999:
            self.max_children = cpu_count()
        elif max_children > 0:
            self.max_children = max_children
        else:
            self.max_children = cpu_count() + max_children
        if self.max_children <= 0:
            raise ValueError("Number of child threads must be greater than 0")
        self.child_name_prefix = child_name_prefix + "-" if child_name_prefix else "ThreadPool%s-" % id(self)
        self.result_id = result_id
        self._child_cnt = 0
        self._busy_lock = pythread.PyThread_allocate_lock()
        #p self._busy_lock = Lock()  
        self._busy_cnt = 0
        self._delayed = deque()
        self._scheduled = deque()
        self._jobs = deque()
        self._jobs_append = self._jobs.append
        self._jobs_appendleft = self._jobs.appendleft
        self._done = deque()
        self._failed = deque()
        self._done_cnt = Semaphore(0)
        self._failed_cnt = Semaphore(0)
        self._shutdown_children = False
        self._shutdown = False
        self.logger = None
        self.init_callback = init_callback
        if done_callback:
            self._thr_done = Thread(target=self._done_thread, args=(done_callback, ),
                                    name="ThreadPoolDone")
            self._thr_done.daemon = True
            self._thr_done.start()
        else:
            self._thr_done = None
        if failed_callback or log_level:
            if log_level:
                import logging
                self.logger = logging.getLogger(LOGGER_NAME)
                self.logger.propagate = False
                formatter = logging.Formatter(DEFAULT_LOGGING_FORMAT)
                handler = logging.StreamHandler()
                handler.setFormatter(formatter)
                self.logger.addHandler(handler)
                if log_level:
                    self.logger.setLevel(log_level)
            self._thr_failed = Thread(target=self._failed_thread, args=(failed_callback, ),
                                      name="ThreadPoolFailed")
            self._thr_failed.daemon = True
            self._thr_failed.start()
        else:
            self._thr_failed = None
        _pools.add(self)

    def __del__(self):
        pythread.PyThread_free_lock(self._busy_lock)
        if _pools:
            _pools.remove(self)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.shutdown()

    cdef void _busy_lock_inc(self):
    #p def _busy_lock_inc(self):  
        pythread.PyThread_acquire_lock(self._busy_lock, 1)
        #p self._busy_lock.acquire()  
        self._busy_cnt += 1
        pythread.PyThread_release_lock(self._busy_lock)
        #p self._busy_lock.release()  

    cdef void _busy_lock_dec(self):
    #p def _busy_lock_dec(self):  
        pythread.PyThread_acquire_lock(self._busy_lock, 1)
        #p self._busy_lock.acquire()  
        self._busy_cnt -= 1
        pythread.PyThread_release_lock(self._busy_lock)
        #p self._busy_lock.release()  

    def _done_thread(self, done_callback):
        done_popleft = self._done.popleft
        while True:
            try:
                while True:
                    done_callback(done_popleft())
            except:
                if self._shutdown:
                    break
                self._done_cnt.acquire()

    def _failed_thread(self, failed_callback):
        failed_popleft = self._failed.popleft
        logger_exception = None if self.logger is None else self.logger.exception
        while True:
            try:
                if failed_callback is None:
                    if logger_exception is None:
                        while True:
                            failed_popleft()
                    else:
                        while True:
                            logger_exception(failed_popleft()[1])
                else:
                    while True:
                        failed_callback(failed_popleft()[1])
            except:
                if self._shutdown:
                    break
                self._failed_cnt.acquire()

    def _child(self, num):
        cdef bint run_child, pop_failed
        self._busy_lock_inc()
        child_busy = True
        _done_append = self._done.append
        failed_append = self._failed.append
        jobs_popleft = self._jobs.popleft
        run_child = True
        pop_failed = False
        while run_child:
            try:
                while True:
                    if not child_busy:
                        self._busy_lock_inc()
                        child_busy = True
                    pop_failed = True
                    job = jobs_popleft()
                    pop_failed = False
                    if job is None or self._shutdown_children:
                        self._job_cnt.release()
                        run_child = False
                        break
                    fn, done_callback, args, kwargs = job
                    if done_callback is False:
                        if isgeneratorfunction(fn):
                            for _ in fn(*args, **kwargs):
                                pass
                        else:
                            fn(*args, **kwargs)
                    elif done_callback is True:
                        if isgeneratorfunction(fn):
                            jobid = id(job)
                            for result in fn(*args, **kwargs):
                                if self.result_id:
                                    _done_append((jobid, result))
                                else:
                                    _done_append(result)
                                self._done_cnt.release()
                        else:
                            if self.result_id:
                                _done_append((id(job), fn(*args, **kwargs)))
                            else:
                                _done_append(fn(*args, **kwargs))
                            self._done_cnt.release()
                    elif callable(done_callback):
                        if isgeneratorfunction(fn):
                            for result in fn(*args, **kwargs):
                                done_callback(result)
                        else:
                            done_callback(fn(*args, **kwargs))
            except Exception as exc:
                if self._shutdown_children:
                    self._job_cnt.release()
                    break
                if pop_failed:
                    self._busy_lock_dec()
                    child_busy = False
                    self._job_cnt.acquire()
                else:
                    if self.result_id:
                        failed_append((id(job), exc))
                    else:
                        failed_append(exc)
                    self._failed_cnt.release()
        self._busy_lock_dec()

    cdef object _submit(self, fn, done_callback, args, kwargs, bint high_priority) except +:
    #p def _submit(self, fn, done_callback, args, kwargs, high_priority):  
        if self._shutdown_children:
            raise PoolStopped("Pool not running")
        if (self._job_cnt._value >= self._child_cnt) and (self._child_cnt < self.max_children):
            self._child_cnt += 1
            thr_child = Thread(target=self._child, args = ( self._child_cnt, ),
                               name=self.child_name_prefix + str(self._child_cnt))
            thr_child.daemon = True
            if self.init_callback is not None:
                self.init_callback(thr_child)
            thr_child.start()
            self.children.add(thr_child)
        job = (fn, done_callback, args, kwargs)
        if high_priority:
            self._jobs_appendleft(job)
        else:
            self._jobs_append(job)
        if  self._job_cnt._value < self._child_cnt:
            self._job_cnt.release()
        if self.result_id:
            return id(job)
        return None

    def submit(self, fn, *args, **kwargs):
        return self._submit(fn, True, args, kwargs, False)

    def submit_done(self, fn, done_callback, *args, **kwargs):
        return self._submit(fn, done_callback, args, kwargs, False)

    def submit_first(self, fn, *args, **kwargs):
        return self._submit(fn, True, args, kwargs, True)

    def submit_done_first(self, fn, done_callback, *args, **kwargs):
        return self._submit(fn, done_callback, args, kwargs, True)

    def _submit_later_do(self, timer_obj, fn, done_callback, args, kwargs):
        self._submit(fn, done_callback, args, kwargs, True)
        self._delayed.remove(timer_obj[0])

    cdef object _submit_later(self, delay, fn, done_callback, args, kwargs) except +:
    #p def _submit_later(self, delay, fn, done_callback, args, kwargs):  
        timer_obj = [None]
        timer = Timer(delay, self._submit_later_do, (timer_obj, fn, done_callback, args, kwargs))
        timer_obj[0] = timer
        timer.start()
        self._delayed.append(timer)
        return timer

    def submit_later(self, delay, fn, *args, **kwargs):
        return self._submit_later(delay, fn, True, args, kwargs)

    def submit_done_later(self, delay, fn, done_callback, *args, **kwargs):
        return self._submit_later(delay, fn, done_callback, args, kwargs)

    cdef object _submit_at(self, _runat, interval, fn, done_callback, args, kwargs) except +:
    #p def _submit_at(self, _runat, interval, fn, done_callback, args, kwargs):  
        if isinstance(_runat, struct_time):
            _runat = mktime(_runat)
        now = _time()
        if _runat < now:
            raise ValueError("_runat has invalid value!")
        timer_obj = TimerObj()
        timer = Timer(_runat - now, self._schedule_do, (timer_obj, _runat - interval, interval,
                                                        fn, done_callback, args, kwargs))
        timer_obj.timer_id = timer
        self._scheduled.append(timer)
        timer.start()
        return timer_obj

    def submit_at(self, _runat, interval, fn, *args, **kwargs):
        return self._submit_at(_runat, interval, fn, True, args, kwargs)

    def submit_done_at(self, _runat, interval, fn, done_callback, *args, **kwargs):
        return self._submit_at(_runat, interval, fn, done_callback, args, kwargs)

    @property
    def delayed(self):
        return self._delayed

    def _schedule_do(self, timer_obj, _runat, interval, fn, done_callback, args, kwargs):
        self._submit(fn, done_callback, args, kwargs, True)
        self._scheduled.remove(timer_obj.timer_id)
        if interval <= 0.0:
            return
        now = _time()
        dt = interval - (now - _runat - interval)
        timer = Timer(dt, self._schedule_do, (timer_obj, now, interval, fn,
                                              done_callback, args, kwargs))
        timer_obj.old_timer_id = timer_obj.timer_id
        timer_obj.timer_id = timer
        self._scheduled.append(timer)
        timer.start()

    cdef object _schedule(self, interval, fn, done_callback, args, kwargs):
    #p def _schedule(self, interval, fn, done_callback, args, kwargs):  
        timer_obj = TimerObj()
        timer = Timer(interval, self._schedule_do, (timer_obj, _time(), interval,
                                                    fn, done_callback, args, kwargs))
        timer_obj.timer_id = timer
        self._scheduled.append(timer)
        timer.start()
        return timer_obj

    def schedule(self, interval, fn, *args, **kwargs):
        return self._schedule(interval, fn, True, args, kwargs)

    def schedule_done(self, interval, fn, done_callback, *args, **kwargs):
        return self._schedule(interval, fn, done_callback, args, kwargs)

    @property
    def scheduled(self):
        return self._scheduled

    def as_completed(self, wait=None):
        cdef float to
        cdef object pyto
        cdef bint do_sleep
        if self._thr_done is not None:
            raise PoolCallback("Using done_callback!")
        if self._thr_failed is not None:
            raise PoolCallback("Using failed_callback!")
        if wait is not False and isinstance(wait, (int, float)):
            pyto = _time() + wait
            to = pyto
        else:
            to = pyto = 0.0
        done = self._done
        failed = self._failed
        done_popleft = done.popleft
        failed_popleft = failed.popleft
        while self._busy_cnt or self._jobs:
            do_sleep = True
            while done:
                yield done_popleft()
                do_sleep = False
            while failed:
                yield failed_popleft()
                do_sleep = False
            if wait is False or ((to > 0.0) and (_time() > pyto)):
                return
            if do_sleep:
                sleep(0.01)

    def _map_child(self, fn, itr, done_callback):
    #p def _map_child(self, fn, itr, done_callback):  
        cdef bint append_done
        self._busy_lock_inc()
        _done_append = self._done.append
        _failed_append = self._failed.append
        if done_callback is False:
            for args in itr:
                if self._shutdown_children:
                    break
                try:
                    fn(args)
                except Exception as exc:
                    _failed_append(exc)
                    self._failed_cnt.release()
        elif done_callback is True:
            for args in itr:
                if self._shutdown_children:
                    break
                try:
                    _done_append(fn(args))
                    self._done_cnt.release()
                except Exception as exc:
                    _failed_append(exc)
                    self._failed_cnt.release()
        elif callable(done_callback):
            for args in itr:
                if self._shutdown_children:
                    break
                try:
                    done_callback(fn(args))
                except Exception as exc:
                    _failed_append(exc)
                    self._failed_cnt.release()
        self._busy_lock_dec()

    def _imap_child(self, fn, itr, done_callback):
    #p def _imap_child(self, fn, itr, done_callback):  
        cdef bint append_done
        self._busy_lock_inc()
        _done_append = self._done.append
        _failed_append = self._failed.append
        if done_callback is False:
            for args in itr:
                if self._shutdown_children:
                    break
                try:
                    for _ in fn(args):
                        pass
                except Exception as exc:
                    _failed_append(exc)
                    self._failed_cnt.release()
        elif done_callback is True:
            for args in itr:
                if self._shutdown_children:
                    break
                try:
                    for result in fn(args):
                        _done_append(result)
                        self._done_cnt.release()
                except Exception as exc:
                    _failed_append(exc)
                    self._failed_cnt.release()
        elif callable(done_callback):
            for args in itr:
                if self._shutdown_children:
                    break
                try:
                    for result in fn(args):
                        done_callback(result)
                except Exception as exc:
                    _failed_append(exc)
                    self._failed_cnt.release()
        self._busy_lock_dec()

    def map(self, fn, itr, done_callback=True):
        cdef int itr_cnt, chunksize
        cdef object pychunksize
        if self._shutdown_children:
            raise PoolStopped("Pool not running")
        for child in tuple(self.children):
            if not child.is_alive():
                self.children.remove(child)
        itr_cnt = len(itr)
        chunksize = itr_cnt // self.max_children
        if itr_cnt % self.max_children:
            pychunksize = chunksize + 1
        else:
            pychunksize = chunksize
        it = iter(itr)
        cb_child = self._imap_child if isgeneratorfunction(fn) else self._map_child
        for _ in range(self.max_children):
            self._child_cnt += 1
            thr_child = Thread(target=cb_child, args=(fn, islice(it, pychunksize), done_callback),
                               name=self.child_name_prefix + str(self._child_cnt))
            thr_child.daemon = True
            if self.init_callback is not None:
                self.init_callback(thr_child)
            thr_child.start()
            self.children.add(thr_child)

    def clear(self):
        self._shutdown_children = False
        self._jobs.clear()
        self._done.clear()
        self._done_cnt = Semaphore(0)
        self._failed.clear()
        self._failed_cnt = Semaphore(0)

    @property
    def alive(self):
        return len([1 for child in self.children if child.is_alive()])

    @property
    def busy(self):
        return self._busy_cnt

    @property
    def pending(self):
        return self._busy_cnt + len(self._jobs)

    @property
    def jobs(self):
        return self._jobs

    @property
    def done(self):
        return self._done

    @property
    def done_cnt(self):
        return self._done_cnt

    @property
    def failed(self):
        return self._failed

    @property
    def failed_cnt(self):
        return self._failed_cnt

    def _join_thread(self, thread, t):
        cdef int cnt
        while True:
            try:
                thread.join(1.0)
                if not thread.is_alive():
                    return thread
                if t is not None and (_time() > t):
                    return None
            except KeyboardInterrupt:
                self._shutdown_children = True
                self._shutdown = True
                raise

    def shutdown_children(self):
        self._shutdown_children = True
        self._job_cnt.release()

    def shutdown(self, timeout=None, soon=False):
        for _ in range(self._child_cnt):
            if soon is True:
                self._jobs.appendleft(None)
            elif soon is False:
                self._jobs_append(None)
        while self._job_cnt._value <= 0:
            self._job_cnt.release()
        t = None if timeout is None else _time() + timeout
        for thread in tuple(self.children):
            self.children.discard(self._join_thread(thread, t))
        if t is not None and (_time() > t):
            self._delayed_cancel()
        if self.children:
            return False
        self._shutdown = True
        if self._thr_done is not None:
            while self._done_cnt._value <= 0:
                self._done_cnt.release()
            self._join_thread(self._thr_done, t)
        if self._thr_failed is not None:
            while self._failed_cnt._value <= 0:
                self._failed_cnt.release()
            self._join_thread(self._thr_failed, t)
        return True

    def join(self, timeout=None):
        return self.shutdown(timeout, False)

    cdef void _delayed_cancel(self):
    #p def _delayed_cancel(self):  
        for timer in self._delayed:
            timer.cancel()
        self._delayed.clear()

    cdef void _scheduled_cancel(self):
    #p def _scheduled_cancel(self):  
        for timer in self._scheduled:
            timer.cancel()
        self._scheduled.clear()

    def cancel(self, job_id=None, timer=None):
        if timer is True:
            self._delayed_cancel()
            self._scheduled_cancel()
        elif isinstance(timer, TimerObj):
            try:
                timer.timer_id.cancel()
                self._scheduled.remove(timer.timer_id)
            except ValueError:
                pass
            try:
                timer.old_timer_id.cancel()
                self._scheduled.remove(timer.old_timer_id)
            except ValueError:
                pass
        elif timer is not None:
            timer.cancel()
            try:
                self._delayed.remove(timer)
            except ValueError:
                pass
            try:
                self._scheduled.remove(timer)
            except ValueError:
                pass
        if job_id is False:
            return True
        if job_id is None:
            self._jobs.clear()
            return True
        for job in self._jobs:
            if id(job) == job_id:
                try:
                    self._jobs.remove(job)
                    return True
                except ValueError:
                    return False
        return False